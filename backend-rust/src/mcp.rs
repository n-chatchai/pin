//! MCP at the proxy — front external MCP servers as blind, minimal-arg tools.
//!
//! The device never speaks MCP and never holds the server's keys: it sees an
//! ordinary remote tool in the catalog and calls `/tool/{name}` with only the
//! declared args. We translate that to an MCP `tools/call` over Streamable HTTP.
//! Ported from the Python `pin_proxy/mcp.py`.

use std::collections::{HashMap, HashSet};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const PROTOCOL_VERSION: &str = "2025-06-18";

fn client(timeout_secs: u64) -> reqwest::Client {
    reqwest::Client::builder()
        .local_address(Some("0.0.0.0".parse().unwrap())) // force IPv4 (Gemini/geo parity)
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .build()
        .unwrap_or_default()
}

fn base_headers(srv: &Value) -> HashMap<String, String> {
    let mut h = HashMap::new();
    h.insert("Content-Type".to_string(), "application/json".to_string());
    h.insert("Accept".to_string(), "application/json, text/event-stream".to_string());
    if let Some(obj) = srv.get("headers").and_then(|v| v.as_object()) {
        for (k, v) in obj {
            if let Some(s) = v.as_str() {
                h.insert(k.clone(), s.to_string());
            }
        }
    }
    h
}

fn anon_user(user: Option<&str>) -> Option<String> {
    let u = user?;
    let mut hasher = Sha256::new();
    hasher.update(u.as_bytes());
    let hex = format!("{:x}", hasher.finalize());
    Some(format!("pin_{}", &hex[..20]))
}

/// One JSON-RPC call. Returns (parsed data, session id). Handles both a plain
/// JSON body and an SSE (text/event-stream) response.
async fn rpc(
    c: &reqwest::Client, url: &str, headers: &HashMap<String, String>,
    rid: u32, method: &str, params: Value,
) -> Result<(Value, Option<String>), String> {
    let mut req = c.post(url).json(&json!({
        "jsonrpc": "2.0", "id": rid, "method": method, "params": params
    }));
    for (k, v) in headers {
        req = req.header(k, v);
    }
    let res = req.send().await.map_err(|e| e.to_string())?;
    if !res.status().is_success() {
        return Err(format!("http {}", res.status()));
    }
    let session = res.headers().get("mcp-session-id")
        .and_then(|h| h.to_str().ok()).map(|s| s.to_string());
    let ctype = res.headers().get("content-type")
        .and_then(|h| h.to_str().ok()).unwrap_or("").to_string();
    let text = res.text().await.map_err(|e| e.to_string())?;
    let data: Value = if ctype.contains("text/event-stream") {
        let mut d = json!({});
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("data:") {
                d = serde_json::from_str(rest.trim()).unwrap_or(json!({}));
                break;
            }
        }
        d
    } else {
        serde_json::from_str(&text).unwrap_or(json!({}))
    };
    Ok((data, session))
}

fn init_params() -> Value {
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "pin-backend", "version": "1"}
    })
}

/// Run an MCP tool via Streamable HTTP JSON-RPC. `entry` is a `mcp_index` value
/// `{server:{url,headers}, tool:{defaults}}`. Returns `{"text": ...}`.
pub async fn call(entry: &Value, name: &str, mut args: Value, user: Option<&str>) -> Value {
    let srv = &entry["server"];

    // Admin-configured defaults, merged for any arg the device didn't send.
    // "$user" → a stable anon hash of the authenticated user_id.
    if let Some(defaults) = entry["tool"].get("defaults").and_then(|v| v.as_object()) {
        if !defaults.is_empty() {
            let anon = anon_user(user);
            if !args.is_object() {
                args = json!({});
            }
            let map = args.as_object_mut().unwrap();
            for (k, v) in defaults {
                if map.contains_key(k) {
                    continue;
                }
                if v == "$user" {
                    if let Some(a) = &anon {
                        map.insert(k.clone(), json!(a));
                    }
                } else {
                    map.insert(k.clone(), v.clone());
                }
            }
        }
    }

    let url = srv["url"].as_str().unwrap_or("");
    let mut headers = base_headers(srv);
    let c = client(90);

    match rpc(&c, url, &headers, 1, "initialize", init_params()).await {
        Ok((_, sid)) => {
            if let Some(s) = sid {
                headers.insert("Mcp-Session-Id".to_string(), s);
            }
        }
        Err(e) => return json!({"text": format!("เครื่องมือ MCP มีปัญหา: {}", e)}),
    }

    match rpc(&c, url, &headers, 2, "tools/call",
              json!({"name": name, "arguments": args})).await {
        Ok((data, _)) => {
            let text: String = data["result"]["content"].as_array()
                .map(|parts| parts.iter()
                    .filter(|p| p.get("type").and_then(|v| v.as_str()) == Some("text"))
                    .filter_map(|p| p.get("text").and_then(|v| v.as_str()))
                    .collect::<String>())
                .unwrap_or_default();
            let text = text.trim();
            json!({"text": if text.is_empty() { "(ไม่มีผลลัพธ์)" } else { text }})
        }
        Err(e) => json!({"text": format!("เครื่องมือ MCP มีปัญหา: {}", e)}),
    }
}

/// Live tools/list from an MCP server (initialize → notifications/initialized → tools/list).
pub async fn list_tools(srv: &Value) -> Result<Vec<Value>, String> {
    let url = srv["url"].as_str().unwrap_or("");
    let mut headers = base_headers(srv);
    let c = client(30);

    let (_, sid) = rpc(&c, url, &headers, 1, "initialize", init_params()).await?;
    if let Some(s) = sid {
        headers.insert("Mcp-Session-Id".to_string(), s);
    }
    // best-effort initialized notification (no id)
    let mut req = c.post(url).json(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
    for (k, v) in &headers {
        req = req.header(k, v);
    }
    let _ = req.send().await;

    let (data, _) = rpc(&c, url, &headers, 2, "tools/list", json!({})).await?;
    Ok(data["result"]["tools"].as_array().cloned().unwrap_or_default())
}

/// Flatten an MCP json-schema property to a device-facing {type,description(+enum)}.
/// MCP wraps optionals in anyOf/null which the device schema doesn't need.
fn simple_prop(schema: &Value) -> Value {
    let mut t = schema.get("type").and_then(|v| v.as_str()).map(String::from);
    let mut enum_v = schema.get("enum").cloned().filter(|v| !v.is_null());
    if t.is_none() {
        if let Some(anyof) = schema.get("anyOf").and_then(|v| v.as_array()) {
            if let Some(opt) = anyof.iter().find(|o|
                o.get("type").and_then(|v| v.as_str()).map_or(false, |s| s != "null")) {
                t = opt.get("type").and_then(|v| v.as_str()).map(String::from);
                if enum_v.is_none() {
                    enum_v = opt.get("enum").cloned().filter(|v| !v.is_null());
                }
            }
        }
    }
    let desc = schema.get("description").and_then(|v| v.as_str())
        .or_else(|| schema.get("title").and_then(|v| v.as_str()))
        .unwrap_or("");
    let mut out = json!({"type": t.unwrap_or_else(|| "string".to_string()), "description": desc});
    if let Some(e) = enum_v {
        out["enum"] = e;
    }
    out
}

/// Re-sync a server's tool schemas from its live tools/list. Proxy-injected params
/// (the tool's `defaults` keys) are kept out of the device-facing schema. Admin
/// display/pricing/status/defaults are preserved by the store layer.
pub async fn refresh_server(store: &crate::store::Store, name: &str) -> Value {
    let srv = match store.get_mcp_server(name).await {
        Ok(Some(s)) => s,
        _ => return json!({"error": format!("no MCP server '{}'", name)}),
    };
    let live = match list_tools(&srv).await {
        Ok(l) => l,
        Err(e) => return json!({"error": e}),
    };
    let index = store.mcp_index().await.unwrap_or_default();
    let mut added: Vec<Value> = vec![];
    let mut updated: Vec<Value> = vec![];

    for t in live {
        let tn = match t.get("name").and_then(|v| v.as_str()) {
            Some(n) => n,
            None => continue,
        };
        let sch = t.get("inputSchema").cloned().unwrap_or(json!({}));
        let injected: HashSet<String> = index.get(tn)
            .and_then(|e| e["tool"]["defaults"].as_object())
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();

        let mut props = serde_json::Map::new();
        if let Some(p) = sch.get("properties").and_then(|v| v.as_object()) {
            for (k, v) in p {
                if !injected.contains(k) {
                    props.insert(k.clone(), simple_prop(v));
                }
            }
        }
        let required: Vec<Value> = sch.get("required").and_then(|v| v.as_array())
            .map(|a| a.iter()
                .filter(|r| r.as_str().map_or(true, |s| !injected.contains(s)))
                .cloned().collect())
            .unwrap_or_default();
        let arg_keys: Vec<Value> = props.keys().map(|k| json!(k)).collect();
        let params = json!({"type": "object", "properties": Value::Object(props), "required": required});
        let desc = t.get("description").and_then(|v| v.as_str()).unwrap_or("");

        match store.refresh_mcp_tool(name, tn, desc, &params, &json!(arg_keys)).await {
            Ok(true) => added.push(json!(tn)),
            Ok(false) => updated.push(json!(tn)),
            Err(_) => {}
        }
    }
    json!({"added": added, "updated": updated})
}
