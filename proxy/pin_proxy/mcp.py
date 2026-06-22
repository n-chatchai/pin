"""MCP at the proxy — front external MCP servers as blind, minimal-arg tools.

The device never speaks MCP and never holds the server's keys: it sees an
ordinary remote tool in the catalog and calls `/tool/{name}` with only the
declared args. We translate that to an MCP `tools/call` over Streamable HTTP.

Config (env `PIN_MCP_SERVERS`, JSON) — tools are *declared* here, not
auto-enumerated, so each one's `argKeys` allowlist is pinned on purpose (the
audit step). Example:

    [{"name":"notion","url":"https://notion.mcp.host/mcp",
      "headers":{"Authorization":"Bearer ..."},
      "tools":[{"name":"notion_search","description":"ค้นใน Notion",
                "parameters":{"type":"object","properties":{"query":{"type":"string"}}},
                "argKeys":["query"]}]}]

With no config, everything here no-ops (empty catalog, 404 on call).
"""

from __future__ import annotations

import json

import httpx

from . import store


def is_mcp(name: str) -> bool:
    return name in store.mcp_index()


async def call(name: str, args: dict, user: str | None = None) -> dict:
    """Run an MCP tool via Streamable HTTP JSON-RPC. Returns {"text": ...}."""
    entry = store.mcp_index().get(name)
    if entry is None:
        return {"text": f"ไม่พบเครื่องมือ MCP '{name}'"}
    srv = entry["server"]
    # Admin-configured default params (mcp_tools.defaults_json), merged in for any
    # arg the device didn't send. The special value "$user" becomes a stable, anon
    # hash of the authenticated user_id — so e.g. lakkana's per-user end_user_ref
    # is filled by the proxy and the DEVICE never sends identity. Configurable per
    # tool via admin; no hardcoded tool names.
    defaults = entry["tool"].get("defaults") or {}
    if defaults:
        import hashlib
        anon = ("pin_" + hashlib.sha256(user.encode()).hexdigest()[:20]) if user else None
        merged = dict(args)
        for k, v in defaults.items():
            if k in merged:
                continue
            if v == "$user":
                if anon:
                    merged[k] = anon
            else:
                merged[k] = v
        args = merged
    url = srv["url"]
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        **(srv.get("headers") or {}),
    }
    try:
        # Generous read timeout: an MCP tool may be LLM-backed (e.g. lakkana's
        # astrology reading runs ~35s), so 30s would race a cold call and surface
        # as an empty-message ReadTimeout. Connect stays short to fail fast.
        async with httpx.AsyncClient(
                timeout=httpx.Timeout(90.0, connect=10.0)) as c:
            # 1) initialize → capture the session id the server may require.
            init = await _rpc(c, url, headers, 1, "initialize", {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "pin-proxy", "version": "1"},
            })
            sid = init["session"]
            if sid:
                headers["Mcp-Session-Id"] = sid
            # 2) tools/call (the actual invocation).
            res = await _rpc(c, url, headers, 2, "tools/call",
                             {"name": name, "arguments": args})
        result = res["data"].get("result", {})
        parts = result.get("content", [])
        text = "".join(p.get("text", "") for p in parts if p.get("type") == "text")
        return {"text": text.strip() or "(ไม่มีผลลัพธ์)"}
    except Exception as e:  # noqa: BLE001
        # Timeouts stringify to "" — fall back to the type so the log isn't blank.
        return {"text": f"เครื่องมือ MCP มีปัญหา: {e or type(e).__name__}"}


def _simple_prop(schema: dict) -> dict:
    """Flatten an MCP json-schema property to a device-facing {type,description}
    (+enum when the value is constrained — the agent needs the allowed values to
    pick a valid one). MCP wraps optionals in anyOf/null which the device schema
    doesn't need; for those the enum hides inside the non-null anyOf branch."""
    t = schema.get("type")
    enum = schema.get("enum")
    if not t and schema.get("anyOf"):
        opt = next((o for o in schema["anyOf"]
                    if o.get("type") not in (None, "null")), {})
        t, enum = opt.get("type"), enum or opt.get("enum")
    out = {"type": t or "string",
           "description": schema.get("description") or schema.get("title") or ""}
    if enum:
        out["enum"] = enum
    return out


async def list_tools(srv: dict) -> list[dict]:
    """Live tools/list from an MCP server (initialize → tools/list)."""
    url = srv["url"]
    headers = {"Content-Type": "application/json",
               "Accept": "application/json, text/event-stream",
               **(srv.get("headers") or {})}
    async with httpx.AsyncClient(timeout=30) as c:
        init = await _rpc(c, url, headers, 1, "initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "pin-proxy", "version": "1"}})
        if init["session"]:
            headers["Mcp-Session-Id"] = init["session"]
        try:
            await c.post(url, headers=headers,
                         json={"jsonrpc": "2.0", "method": "notifications/initialized"})
        except Exception:  # noqa: BLE001
            pass
        res = await _rpc(c, url, headers, 2, "tools/list", {})
    return res["data"].get("result", {}).get("tools", []) or []


async def refresh_server(name: str) -> dict:
    """Re-sync a server's tool schemas from its live tools/list. Params that the
    proxy injects (the tool's `defaults` keys, e.g. $user end_user_ref) are kept
    out of the device-facing schema. Admin display/pricing/status/defaults are
    preserved."""
    srv = store.get_mcp_server(name)
    if not srv:
        return {"error": f"no MCP server '{name}'"}
    live = await list_tools(srv)
    existing = {n: (e["tool"].get("defaults") or {})
                for n, e in store.mcp_index().items()}
    out: dict = {"updated": [], "added": []}
    for t in live:
        tn = t["name"]
        sch = t.get("inputSchema", {}) or {}
        injected = set((existing.get(tn) or {}).keys())
        props = {k: _simple_prop(v) for k, v in (sch.get("properties") or {}).items()
                 if k not in injected}
        required = [r for r in (sch.get("required") or []) if r not in injected]
        params = {"type": "object", "properties": props, "required": required}
        is_new = store.refresh_mcp_tool(name, tn, t.get("description", ""),
                                        params, list(props.keys()))
        out["added" if is_new else "updated"].append(tn)
    return out


async def _rpc(c, url, headers, rid, method, params) -> dict:
    """One JSON-RPC call; returns {"data": parsed, "session": id|None}. Handles
    both a plain JSON body and an SSE (text/event-stream) response."""
    r = await c.post(url, headers=headers,
                     json={"jsonrpc": "2.0", "id": rid, "method": method,
                           "params": params})
    r.raise_for_status()
    session = r.headers.get("mcp-session-id")
    ctype = r.headers.get("content-type", "")
    if "text/event-stream" in ctype:
        data = {}
        for line in r.text.splitlines():
            if line.startswith("data:"):
                data = json.loads(line[5:].strip())
                break
    else:
        data = r.json()
    return {"data": data, "session": session}
