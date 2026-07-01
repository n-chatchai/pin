use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use time;
use axum::{
    http::{StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    extract::{Path, Query, State},
    Form,
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use pyo3::prelude::*;
use pyo3::types::PyDict;
use tracing::{error, warn};

use crate::store::Store;
use crate::emails;
use crate::proxy::Scheduler;
use sqlx::Row;

const COOKIE_NAME: &str = "pin_admin";

#[derive(Serialize, Deserialize, Clone)]
pub struct AdminClaims {
    pub email: String,
    pub exp: i64,
}

// State shared across Axum handlers
#[derive(Clone)]
pub struct AdminState {
    pub store: Store,
    pub jinja_env: minijinja::Environment<'static>,
    pub jwt_secret: String,
    pub scheduler: Arc<Scheduler>,
}

// Google OAuth config
// Helper to validate the admin session
async fn get_admin_session(jar: &CookieJar, secret: &str, store: &Store) -> Option<String> {
    let cookie = jar.get(COOKIE_NAME)?;
    let token = cookie.value();
    
    let key = jsonwebtoken::DecodingKey::from_secret(secret.as_bytes());
    let validation = jsonwebtoken::Validation::default();
    
    if let Ok(data) = jsonwebtoken::decode::<AdminClaims>(token, &key, &validation) {
        let email = data.claims.email;
        if store.is_admin(&email).await.unwrap_or(false) {
            return Some(email);
        }
    }
    None
}

// Helper to render templates
fn render(env: &minijinja::Environment, template: &str, ctx: Value) -> Response {
    match env.get_template(template) {
        Ok(tmpl) => match tmpl.render(ctx) {
            Ok(html) => Html(html).into_response(),
            Err(e) => {
                error!("Template rendering failed for {}: {:?}", template, e);
                (StatusCode::INTERNAL_SERVER_ERROR, format!("Render error: {:?}", e)).into_response()
            }
        },
        Err(e) => {
            error!("Template retrieval failed for {}: {:?}", template, e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("Template error: {:?}", e)).into_response()
        }
    }
}

// ---- Routes ----

pub async fn login_page(State(state): State<AdminState>, jar: CookieJar, Query(params): Query<HashMap<String, String>>) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_some() {
        return Redirect::to("/admin").into_response();
    }
    let error = params.get("error").map(|e| match e.as_str() {
        "unauthorized" => "คุณไม่ได้รับอนุญาตให้เข้าใช้งานระบบหลังบ้าน",
        "google_failed" => "การเข้าสู่ระบบผ่าน Google ล้มเหลว",
        _ => "เข้าสู่ระบบไม่สำเร็จ"
    });
    render(&state.jinja_env, "login.html", json!({ "error": error }))
}

pub async fn logout(_jar: CookieJar) -> impl IntoResponse {
    let mut resp = Redirect::to("/admin/login").into_response();
    let cookie = Cookie::build((COOKIE_NAME, ""))
        .path("/admin")
        .http_only(true)
        .build();
    resp.headers_mut().append(
        header::SET_COOKIE,
        cookie.to_string().parse().unwrap()
    );
    resp
}

/// Kick off admin login via the homeserver's SSO (which fronts Google) — the
/// SAME tuwunel identity_provider the app uses. No separate admin Google client.
/// The browser must hit the PUBLIC homeserver; the loginToken is exchanged
/// server-side over the internal address in `sso_callback`.
pub async fn sso_login() -> Response {
    let hs_public = std::env::var("PIN_HOMESERVER_PUBLIC")
        .unwrap_or_else(|_| "https://pin-chat.tokens2.io".to_string());
    let callback = std::env::var("PIN_ADMIN_SSO_CALLBACK")
        .unwrap_or_else(|_| "https://pin-backend.tokens2.io/admin/sso/callback".to_string());
    let url = format!(
        "{}/_matrix/client/v3/login/sso/redirect?redirectUrl={}",
        hs_public, urlencoding::encode(&callback)
    );
    Redirect::to(&url).into_response()
}

/// Homeserver redirects here with `?loginToken=...`. Exchange it for a Matrix
/// session (m.login.token), check the user_id against the owners allowlist, then
/// issue the admin cookie. The ephemeral Matrix session is logged out right after.
pub async fn sso_callback(
    State(state): State<AdminState>,
    _jar: CookieJar,
    Query(params): Query<HashMap<String, String>>
) -> Response {
    let login_token = match params.get("loginToken") {
        Some(t) => t,
        None => return Redirect::to("/admin/login?error=sso_failed").into_response(),
    };

    let hs = std::env::var("PIN_HOMESERVER")
        .unwrap_or_else(|_| "http://10.42.0.1:6167".to_string());
    let client = reqwest::Client::new();

    let res = match client.post(format!("{}/_matrix/client/v3/login", hs))
        .json(&json!({"type": "m.login.token", "token": login_token}))
        .send().await
    {
        Ok(r) => r,
        Err(_) => return Redirect::to("/admin/login?error=sso_failed").into_response(),
    };

    #[derive(Deserialize)]
    struct LoginResp { user_id: String, access_token: Option<String> }

    let body = match res.json::<LoginResp>().await {
        Ok(b) => b,
        Err(_) => return Redirect::to("/admin/login?error=sso_failed").into_response(),
    };
    let user_id = body.user_id;

    // Best-effort logout of the throwaway Matrix session — we only needed identity.
    if let Some(tok) = &body.access_token {
        let _ = client.post(format!("{}/_matrix/client/v3/logout", hs))
            .header("Authorization", format!("Bearer {}", tok)).send().await;
    }

    if !state.store.is_admin(&user_id).await.unwrap_or(false) {
        warn!("Unauthorized admin SSO attempt: {}", user_id);
        return Redirect::to("/admin/login?error=unauthorized").into_response();
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let claims = AdminClaims {
        email: user_id, // holds the Matrix user_id
        exp: (now + 8 * 3600) as i64,
    };
    
    let key = jsonwebtoken::EncodingKey::from_secret(state.jwt_secret.as_bytes());
    let token = match jsonwebtoken::encode(&jsonwebtoken::Header::default(), &claims, &key) {
        Ok(t) => t,
        Err(_) => return Redirect::to("/admin/login?error=google_failed").into_response(),
    };

    let cookie = Cookie::build((COOKIE_NAME, token))
        .path("/admin")
        .http_only(true)
        .same_site(axum_extra::extract::cookie::SameSite::Lax)
        .max_age(time::Duration::seconds(8 * 3600))
        .build();

    let mut resp = Redirect::to("/admin").into_response();
    resp.headers_mut().append(
        header::SET_COOKIE,
        cookie.to_string().parse().unwrap()
    );
    resp
}

pub async fn dashboard(State(state): State<AdminState>, jar: CookieJar) -> Response {
    let admin = match get_admin_session(&jar, &state.jwt_secret, &state.store).await {
        Some(email) => email,
        None => return Redirect::to("/admin/login").into_response(),
    };

    let counts = match get_dashboard_counts(&state.store).await {
        Ok(c) => c,
        Err(_) => json!({ "tools": 0, "skills": 0, "subagents": 0, "mcp": 0, "backlog": 0 }),
    };

    render(&state.jinja_env, "dashboard.html", json!({
        "admin": admin,
        "counts": counts
    }))
}

async fn get_dashboard_counts(store: &Store) -> Result<Value, sqlx::Error> {
    let capabilities = store.all_capabilities().await?;
    let mut tools = 0;
    let mut skills = 0;

    for cap in capabilities {
        match cap.get("kind").and_then(|v| v.as_str()) {
            Some("tool") => tools += 1,
            Some("skill") => skills += 1,
            _ => {}
        }
    }

    let backlog = store.list_capability_requests().await?
        .iter()
        .filter(|r| r.get("status").and_then(|v| v.as_str()) != Some("done"))
        .count();

    let subagents = store.enabled_subagents().await?.len();
    let mcp_servers = store.installed_names("mcp_servers").await?.len();

    Ok(json!({
        "tools": tools,
        "skills": skills,
        "subagents": subagents,
        "mcp": mcp_servers,
        "backlog": backlog,
    }))
}

// ---- Tabs ----

pub async fn tab_backlog(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let rows = store_list_capability_requests_json(&state.store).await;
    render(&state.jinja_env, "_backlog.html", json!({ "rows": rows }))
}

async fn store_list_capability_requests_json(store: &Store) -> Value {
    let rows = store.list_capability_requests().await.unwrap_or_default();
    json!(rows)
}

pub async fn set_backlog_status(
    State(state): State<AdminState>, jar: CookieJar, Path((req_id, status)): Path<(i32, String)>
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    if status == "requested" || status == "building" || status == "done" {
        let _ = state.store.set_capability_status(req_id, &status).await;
    }
    let rows = store_list_capability_requests_json(&state.store).await;
    render(&state.jinja_env, "_backlog.html", json!({ "rows": rows }))
}

// --- Push tab ---

pub async fn tab_push(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let rows = get_push_rows(&state.store).await;
    render(&state.jinja_env, "_push.html", json!({ "rows": rows }))
}

#[derive(Deserialize)]
pub struct WakeForm {
    pub user_id: String,
}

pub async fn push_wake(
    State(state): State<AdminState>,
    jar: CookieJar,
    Form(f): Form<WakeForm>,
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    
    let devices = state.store.list_push_devices().await.unwrap_or_default();
    let dev = devices.iter().find(|d| d.get("user_id").and_then(|v| v.as_str()) == Some(&f.user_id));
    
    let mut msg = "ไม่พบอุปกรณ์".to_string();
    if let Some(d) = dev {
        let token = d.get("device").and_then(|v| v.as_str()).unwrap_or("");
        let platform = d.get("platform").and_then(|v| v.as_str()).unwrap_or("apns");
        if !token.is_empty() {
            match state.scheduler.push(token, "admin-wake", platform, true).await {
                Ok(_) => msg = format!("ปลุก {} แล้ว ({})", f.user_id, platform),
                Err(e) => msg = format!("ปลุกไม่สำเร็จ: {:?}", e),
            }
        }
    }
    
    let rows = get_push_rows(&state.store).await;
    render(&state.jinja_env, "_push.html", json!({ "rows": rows, "flash": msg }))
}

pub async fn push_catalog(
    State(state): State<AdminState>,
    jar: CookieJar,
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    
    let devices = state.store.list_push_devices().await.unwrap_or_default();
    let mut sent = 0;
    
    for d in devices {
        let token = d.get("device").and_then(|v| v.as_str()).unwrap_or("");
        let platform = d.get("platform").and_then(|v| v.as_str()).unwrap_or("apns");
        if !token.is_empty() {
            // We use 'catalog_update' as the payload, keeping is_silent = true
            let _ = state.scheduler.push(token, "catalog_update", platform, true).await;
            sent += 1;
        }
    }
    
    let msg = format!("ส่งคำสั่งอัปเดต Catalog ไป {} เครื่องเรียบร้อยแล้ว", sent);
    let rows = get_push_rows(&state.store).await;
    render(&state.jinja_env, "_push.html", json!({ "rows": rows, "flash": msg }))
}

async fn get_push_rows(store: &Store) -> Vec<Value> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
    let mut rows = store.list_push_devices().await.unwrap_or_default();
    for r in &mut rows {
        let updated = r.get("updated_at").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let age = now - updated;
        let ago = if age < 3600.0 {
            "เมื่อกี้".to_string()
        } else if age < 86400.0 {
            format!("{} ชม.ก่อน", (age / 3600.0) as i32)
        } else {
            format!("{} วันก่อน", (age / 86400.0) as i32)
        };
        r["ago"] = json!(ago);
        
        let device = r.get("device").and_then(|v| v.as_str()).unwrap_or("");
        let device_short = if device.len() > 16 {
            format!("{}…", &device[..16])
        } else {
            device.to_string()
        };
        r["device_short"] = json!(device_short);
    }
    rows
}

// --- Store Tab ---

// Back-compat alias — the store tab is now the Capabilities view.
pub async fn tab_store(State(state): State<AdminState>, jar: CookieJar) -> Response {
    tab_capabilities(State(state), jar).await
}

pub async fn store_toggle(State(state): State<AdminState>, jar: CookieJar, Path(name): Path<String>) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let _ = state.store.toggle_capability(&name).await;
    tab_capabilities(State(state), jar).await
}

// --- 3-entity admin: Capabilities / Connectors / Assistants ---

/// Capabilities grouped by kind (tool/skill/subagent/mcp).
pub async fn tab_capabilities(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let caps = state.store.all_capabilities_admin().await.unwrap_or_default();
    let mut groups = Vec::new();
    for (kind, label) in [("tool", "เครื่องมือ"), ("skill", "ทักษะ"), ("mcp", "MCP")] {
        let items: Vec<Value> = caps.iter()
            .filter(|c| c.get("kind").and_then(|v| v.as_str()) == Some(kind))
            .cloned().collect();
        if !items.is_empty() {
            groups.push(json!({"kind": kind, "label": label, "items": items}));
        }
    }
    render(&state.jinja_env, "_capabilities.html", json!({"groups": groups}))
}

/// Connectors (MCP servers etc.) with their tools + refresh.
pub async fn tab_connectors(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let connectors = state.store.all_connectors().await.unwrap_or_default();
    render(&state.jinja_env, "_connectors.html", json!({"connectors": connectors}))
}

/// ผู้ช่วย = subagents (delegate/handoff agents). Each is a brain the main bot
/// hands work to; the assistants-package table isn't used yet (YAGNI).
pub async fn tab_assistants(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let assistants = state.store.enabled_assistants().await.unwrap_or_default();
    render(&state.jinja_env, "_assistants.html", json!({"assistants": assistants}))
}

#[derive(Deserialize)]
pub struct StoreMetaForm {
    pub category: Option<String>,
    pub status: Option<String>,
    pub tier: Option<String>,
    pub amount: Option<String>,
    pub period: Option<String>,
    pub render: Option<String>,
    pub ask_params: Option<String>,
}

pub async fn store_save(
    State(state): State<AdminState>, jar: CookieJar, Path(name): Path<String>, Form(f): Form<StoreMetaForm>
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    
    let _ = state.store.set_store_meta(
        &name,
        f.category.as_deref(),
        f.status.as_deref(),
        f.tier.as_deref(),
        f.amount.as_deref(),
        f.period.as_deref(),
        f.render.as_deref(),
        f.ask_params.as_deref()
    ).await;
    
    tab_store(State(state), jar).await
}

// --- MCP Config ---

/// Live-refresh an MCP server's tool schemas (tools/list → capabilities).
pub async fn mcp_refresh(State(state): State<AdminState>, jar: CookieJar, Path(server): Path<String>) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let _ = crate::mcp::refresh_server(&state.store, &server).await;
    tab_connectors(State(state), jar).await
}

/// List an MCP server's stored tools (name, params, defaults) for the admin UI.
pub async fn mcp_server_tools(State(state): State<AdminState>, jar: CookieJar, Path(server): Path<String>) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let tools = state.store.mcp_tools_for_server(&server).await.unwrap_or_default();
    axum::Json(serde_json::json!({ "server": server, "tools": tools })).into_response()
}

// --- Waitlist Tab ---

pub async fn tab_waitlist(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    wl_render(&state.jinja_env, &state.store, "").await
}

async fn wl_render(env: &minijinja::Environment<'static>, store: &Store, flash: &str) -> Response {
    let mut rows = store.list_waitlist().await.unwrap_or_default();
    let replies = store.mail_reply_counts().await.unwrap_or_default();
    
    let mut unsent = 0;
    for r in &mut rows {
        let use_case = r.get("use").and_then(|v| v.as_str()).unwrap_or("");
        let persona = emails::classify(use_case);
        let persona_th = match persona {
            "study" => "ติว/ทบทวน",
            "home" => "เรื่องในบ้าน",
            "creative" => "ครีเอทีฟ",
            "sme" => "ร้านค้า",
            "work" => "จัดการงาน",
            _ => "ทั่วไป"
        };
        r["persona_th"] = json!(persona_th);
        
        let sent_at = r.get("sent_at").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let sent = sent_at > 0.0;
        r["sent"] = json!(sent);
        
        let unsub = r.get("unsubscribed_at").and_then(|v| v.as_f64()).unwrap_or(0.0) > 0.0;
        r["unsub"] = json!(unsub);
        
        let email = r.get("email").and_then(|v| v.as_str()).unwrap_or("");
        r["replies"] = json!(replies.get(email).cloned().unwrap_or(0));
        
        if sent {
            // format time
            let local_time = chrono::DateTime::from_timestamp(sent_at as i64, 0)
                .map(|dt| dt.with_timezone(&chrono::Local).format("%d/%m %H:%M").to_string())
                .unwrap_or_default();
            r["sent_th"] = json!(local_time);
        } else {
            r["sent_th"] = json!("");
            if !unsub {
                unsent += 1;
            }
        }
    }

    render(env, "_waitlist.html", json!({
        "rows": rows,
        "flash": flash,
        "unsent": unsent
    }))
}

// Mail message checker using PyO3 imaplib wrapper
fn poll_imap_mail() -> Result<Vec<Value>, String> {
    Python::with_gil(|py| {
        let code = r#"
import os
import imaplib
import email as emaillib
from email.utils import parseaddr

def poll_mail_py():
    user = os.environ.get("GMAIL_USER", "chatchai@tokens2.io")
    pw = (os.environ.get("GG_APP_PASSWORD_PIN")
          or os.environ.get("GMAIL_APP_PASSWORD", "")).replace(" ", "")
    
    out = []
    if not pw:
        return out
        
    try:
        M = imaplib.IMAP4_SSL("imap.gmail.com", 993)
        M.login(user, pw)
        M.select("INBOX")
        typ, data = M.search(None, "UNSEEN")
        for num in (data[0] or b"").split():
            typ, md = M.fetch(num, "(RFC822)")
            if not md or not md[0]:
                continue
            m = emaillib.message_from_bytes(md[0][1])
            frm = parseaddr(m.get("From", ""))[1].lower()
            msgid = (m.get("Message-ID") or "").strip()
            irt = (m.get("In-Reply-To") or "").strip()
            
            # Extract plain text
            body = ""
            parts = m.walk() if m.is_multipart() else [m]
            for part in parts:
                if part.get_content_type() == "text/plain" and "attachment" not in str(part.get("Content-Disposition", "")):
                    try:
                        body = part.get_payload(decode=True).decode(part.get_content_charset() or "utf-8", "replace")
                    except:
                        pass
                    break
            
            # cut quoted reply
            import re
            body = re.split(r"\n\s*On .*wrote:\s*\n|\n\s*>", body, maxsplit=1)[0].strip()
            
            out.append({
                "from": frm,
                "msg_id": msgid,
                "in_reply_to": irt,
                "subject": m.get("Subject", ""),
                "body": body
            })
            M.store(num, "+FLAGS", "\\Seen")
        M.logout()
    except Exception as e:
        print("IMAP Poll Error:", e)
    return out
"#;
        let locals = PyDict::new_bound(py);
        py.run_bound(code, None, Some(&locals)).map_err(|e| e.to_string())?;
        let func = locals.get_item("poll_mail_py")
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Failed to find poll_mail_py function".to_string())?;
        
        let py_list = func.call0().map_err(|e| e.to_string())?;
        let list_str: String = py.import_bound("json")
            .map_err(|e| e.to_string())?
            .call_method1("dumps", (py_list,))
            .map_err(|e| e.to_string())?
            .extract()
            .map_err(|e| e.to_string())?;
            
        let vec_val = serde_json::from_str(&list_str).map_err(|e| e.to_string())?;
        Ok(vec_val)
    })
}

// Mail message sender using PyO3 smtplib wrapper
fn send_mail_via_python(to: &str, subject: &str, text: &str, html: &str) -> Result<String, String> {
    Python::with_gil(|py| {
        let code = r#"
import os
import smtplib
from email.message import EmailMessage
from email.utils import make_msgid

def send_email_py(to, subject, text, html):
    user = os.environ.get("GMAIL_USER", "chatchai@tokens2.io")
    pw = (os.environ.get("GG_APP_PASSWORD_PIN")
          or os.environ.get("GMAIL_APP_PASSWORD", "")).replace(" ", "")
    sender = os.environ.get("GMAIL_FROM", "ปิ่น <pin@tokens2.io>")
    
    msg_id = make_msgid(domain="tokens2.io")
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to
    msg["Reply-To"] = sender
    msg["Message-ID"] = msg_id
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as s:
        s.starttls()
        s.login(user, pw)
        s.send_message(msg)
    return msg_id
"#;
        let locals = PyDict::new_bound(py);
        py.run_bound(code, None, Some(&locals)).map_err(|e| e.to_string())?;
        let func = locals.get_item("send_email_py")
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Failed to find send_email_py function".to_string())?;
        
        let msg_id: String = func.call1((to, subject, text, html))
            .map_err(|e| e.to_string())?
            .extract()
            .map_err(|e| e.to_string())?;
            
        Ok(msg_id)
    })
}

pub async fn waitlist_poll(State(state): State<AdminState>, jar: CookieJar) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    match poll_imap_mail() {
        Ok(emails) => {
            let wl_set = state.store.waitlist_email_set().await.unwrap_or_default();
            let out_idx = state.store.mail_out_index().await.unwrap_or_default();
            let mut added = 0;

            for m in emails {
                let frm = m["from"].as_str().unwrap_or("").to_lowercase();
                let msg_id = m["msg_id"].as_str().unwrap_or("");
                let irt = m["in_reply_to"].as_str().unwrap_or("");
                
                let who = if wl_set.contains(&frm) {
                    Some(frm)
                } else {
                    out_idx.get(irt).cloned()
                };

                if let Some(email) = who {
                    if let Ok(false) = state.store.mail_msgid_seen(msg_id).await {
                        let subject = m["subject"].as_str().unwrap_or("");
                        let body = m["body"].as_str().unwrap_or("");
                        
                        let _ = state.store.add_mail_message(&email, "in", subject, body, msg_id, irt).await;
                        
                        // Check for unsubscribe words
                        let body_low = body.to_lowercase();
                        let unsub_words = vec!["unsubscribe", "เลิกรับ", "ยกเลิกรับ", "ไม่รับ", "เลิกติดตาม", "opt out", "opt-out"];
                        if unsub_words.iter().any(|w| body_low.contains(w)) {
                            let _ = state.store.mark_waitlist_unsubscribed(&email).await;
                        }
                        added += 1;
                    }
                }
            }
            let flash = if added > 0 {
                format!("ดึงเมลแล้ว · reply ใหม่ {}", added)
            } else {
                "ดึงเมลแล้ว · ไม่มี reply ใหม่".to_string()
            };
            wl_render(&state.jinja_env, &state.store, &flash).await
        }
        Err(e) => {
            wl_render(&state.jinja_env, &state.store, &format!("ดึงเมลไม่สำเร็จ: {}", e)).await
        }
    }
}

pub async fn waitlist_thread(
    State(state): State<AdminState>, jar: CookieJar, Path(wid): Path<i32>
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    
    let wl = state.store.list_waitlist().await.unwrap_or_default();
    let row = match wl.iter().find(|r| r["id"].as_i64() == Some(wid as i64)) {
        Some(r) => r,
        None => return (StatusCode::NOT_FOUND, "Not Found").into_response(),
    };

    let email = row["email"].as_str().unwrap_or("");
    let mut msgs = state.store.mail_thread(email).await.unwrap_or_default();
    for m in &mut msgs {
        let ca = m["created_at"].as_f64().unwrap_or(0.0);
        let formatted = chrono::DateTime::from_timestamp(ca as i64, 0)
            .map(|dt| dt.with_timezone(&chrono::Local).format("%d/%m %H:%M").to_string())
            .unwrap_or_default();
        m["ts_th"] = json!(formatted);
    }

    render(&state.jinja_env, "_waitlist_thread.html", json!({
        "to": email,
        "msgs": msgs
    }))
}

pub async fn waitlist_preview(
    State(state): State<AdminState>, jar: CookieJar, Path(wid): Path<i32>
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    let wl = state.store.list_waitlist().await.unwrap_or_default();
    let row = match wl.iter().find(|r| r["id"].as_i64() == Some(wid as i64)) {
        Some(r) => r,
        None => return (StatusCode::NOT_FOUND, "Not Found").into_response(),
    };

    let use_case = row.get("use").and_then(|v| v.as_str()).unwrap_or("");
    let (subject, _, html) = emails::build(use_case);
    
    render(&state.jinja_env, "_waitlist_preview.html", json!({
        "to": row["email"].as_str().unwrap_or(""),
        "subject": subject,
        "html": html,
        "wid": wid,
        "sent": row.get("sent_at").and_then(|v| v.as_f64()).unwrap_or(0.0) > 0.0,
    }))
}

pub async fn waitlist_send(
    State(state): State<AdminState>, jar: CookieJar, Path(wid): Path<i32>
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    let wl = state.store.list_waitlist().await.unwrap_or_default();
    let row = match wl.iter().find(|r| r["id"].as_i64() == Some(wid as i64)) {
        Some(r) => r,
        None => return (StatusCode::NOT_FOUND, "Not Found").into_response(),
    };

    let email = row["email"].as_str().unwrap_or("");
    
    if row.get("unsubscribed_at").and_then(|v| v.as_f64()).unwrap_or(0.0) > 0.0 {
        return wl_render(&state.jinja_env, &state.store, &format!("{} ยกเลิกรับแล้ว — ไม่ส่ง", email)).await;
    }

    let use_case = row.get("use").and_then(|v| v.as_str()).unwrap_or("");
    let (subject, text, html) = emails::build(use_case);

    let flash = match send_mail_via_python(email, &subject, &text, &html) {
        Ok(mid) => {
            let _ = state.store.mark_waitlist_sent(email).await;
            let _ = state.store.add_mail_message(email, "out", &subject, &text, &mid, "").await;
            format!("ส่งหา {} แล้ว ✓", email)
        }
        Err(e) => {
            format!("ส่งไม่สำเร็จ ({}): {}", email, e)
        }
    };

    wl_render(&state.jinja_env, &state.store, &flash).await
}

pub async fn waitlist_send_unsent(
    State(state): State<AdminState>, jar: CookieJar
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    let wl = state.store.list_waitlist().await.unwrap_or_default();
    let mut sent = 0;
    let mut fail = 0;

    for row in wl {
        let sent_at = row.get("sent_at").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let unsub = row.get("unsubscribed_at").and_then(|v| v.as_f64()).unwrap_or(0.0) > 0.0;
        if sent_at > 0.0 || unsub {
            continue;
        }

        let email = row["email"].as_str().unwrap_or("");
        let use_case = row.get("use").and_then(|v| v.as_str()).unwrap_or("");
        let (subject, text, html) = emails::build(use_case);

        match send_mail_via_python(email, &subject, &text, &html) {
            Ok(mid) => {
                let _ = state.store.mark_waitlist_sent(email).await;
                let _ = state.store.add_mail_message(email, "out", &subject, &text, &mid, "").await;
                sent += 1;
            }
            Err(_) => {
                fail += 1;
            }
        }
    }

    wl_render(&state.jinja_env, &state.store, &format!("ส่งสำเร็จ {} · ล้มเหลว {}", sent, fail)).await
}

pub async fn tab_generic(
    State(state): State<AdminState>, jar: CookieJar, Path(tab): Path<String>
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    if tab != "logs" {
        return (StatusCode::NOT_FOUND, "Not Found").into_response();
    }

    // fetch tool logs
    let rows_res = sqlx::query("SELECT ts,tool,kind,arg_keys,status FROM tool_logs ORDER BY ts DESC LIMIT 50")
        .fetch_all(&state.store.pool) // We need public pool on Store. Let's make sure it's accessible.
        ;
    
    // Let's implement it inside store.rs as list_tool_logs instead of raw query here
    // Wait, let's look up if we added list_tool_logs. No, but we can write a query here or in store.rs
    // To keep store encapsulation, let's write it in store.rs, but since we didn't, let's run it directly:
    let rows_val = match sqlx::query("SELECT ts,tool,kind,arg_keys,status FROM tool_logs ORDER BY ts DESC LIMIT 50")
        .fetch_all(&state.store.pool)
        .await
    {
        Ok(rows) => {
            let mut out = Vec::new();
            for r in rows {
                out.push(json!({
                    "ts": r.get::<f64, _>("ts"),
                    "tool": r.get::<Option<String>, _>("tool").unwrap_or_default(),
                    "kind": r.get::<Option<String>, _>("kind").unwrap_or_default(),
                    "arg_keys": r.get::<Option<String>, _>("arg_keys").unwrap_or_default(),
                    "status": r.get::<Option<String>, _>("status").unwrap_or_default(),
                }));
            }
            json!(out)
        }
        Err(_) => json!([])
    };

    render(&state.jinja_env, "_simple.html", json!({ "tab": tab, "rows": rows_val }))
}

pub async fn install_assistant(
    State(state): State<AdminState>,
    jar: CookieJar,
    axum::Json(payload): axum::Json<Value>,
) -> Response {
    if get_admin_session(&jar, &state.jwt_secret, &state.store).await.is_none() {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    
    match state.store.install_assistant(&payload).await {
        Ok(_) => axum::Json(json!({"ok": true})).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}
