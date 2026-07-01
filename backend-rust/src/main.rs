use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use std::str::FromStr;
use std::path::PathBuf;
use axum::{
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
    extract::{Path, Query, State, Multipart},
    Json, Router,
};
use axum_extra::extract::cookie::CookieJar;
use serde_json::{json, Value};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use tracing::{info, warn, error};
use tracing_subscriber::EnvFilter;

mod display;
mod store;
mod proxy;
mod emails;
mod admin;
mod converter;
mod mcp;

use store::Store;
use proxy::{MatrixAuth, GoogleAuth, Scheduler, LLMForwarder};
use admin::AdminState;

// Shared App State
struct AppState {
    store: Store,
    matrix_auth: MatrixAuth,
    scheduler: Arc<Scheduler>,
    forwarder: LLMForwarder,
}

fn fromjson_filter(val: String) -> Result<minijinja::value::Value, minijinja::Error> {
    if val.is_empty() {
        Ok(minijinja::value::Value::from(Vec::<String>::new()))
    } else {
        let parsed: serde_json::Value = serde_json::from_str(&val).map_err(|e| {
            minijinja::Error::new(minijinja::ErrorKind::InvalidOperation, format!("fromjson error: {:?}", e))
        })?;
        Ok(minijinja::value::Value::from_serialize(parsed))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. Load environment variables
    let _ = dotenvy::dotenv();

    // 2. Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    // 3. Connect to SQLite database
    let db_path = std::env::var("PIN_DB").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        format!("{}/pin.db", home)
    });
    info!("Using database: {}", db_path);
    
    let db_url = format!("sqlite://{}", db_path);
    let options = SqliteConnectOptions::from_str(&db_url)?
        .create_if_missing(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
        
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?;

    let store = Store::new(pool);
    store.init().await?;

    // 4. Initialize auth clients
    let homeserver = std::env::var("PIN_HOMESERVER").unwrap_or_else(|_| "http://127.0.0.1:6167".to_string());
    let ttl_secs = std::env::var("PIN_WHOAMI_TTL").ok().and_then(|s| s.parse().ok()).unwrap_or(300);
    let matrix_auth = MatrixAuth::new(homeserver, ttl_secs);

    let fcm_sa_path = std::env::var("FCM_SA_PATH").ok();
    let fcm_project_id = std::env::var("FCM_PROJECT_ID").unwrap_or_else(|_| "pin-ai-b9d8a".to_string());
    let google_auth = Arc::new(GoogleAuth::new(fcm_sa_path, fcm_project_id));

    // APNs configurations
    let scheduler = Arc::new(Scheduler::new(store.clone(), google_auth));

    // LLM Models
    let free_model = store.get_setting("pin_free_model").await.unwrap_or(None).unwrap_or_else(|| "gemini-flash-lite-latest".to_string());
    let forwarder = LLMForwarder::new(free_model);

    // 5. Initialize Python (PyO3) and test markitdown import
    pyo3::prepare_freethreaded_python();
    if let Err(e) = converter::test_markitdown_import() {
        warn!("Warning: Failed to import 'markitdown' in Python. File conversion will fail. Error: {}", e);
    } else {
        info!("PyO3: 'markitdown' imported successfully!");
    }

    // 6. Spawn scheduler poller in the background
    let sched_clone = scheduler.clone();
    tokio::spawn(async move {
        info!("[sched] poller loop started");
        loop {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
            sched_clone.fire_due(now).await;
            tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
        }
    });

    // 7. Setup minijinja templating engine
    let mut jinja_env = minijinja::Environment::new();
    jinja_env.set_loader(minijinja::path_loader("templates"));
    jinja_env.add_filter("fromjson", fromjson_filter);

    let jwt_secret = std::env::var("PIN_ADMIN_SECRET").unwrap_or_else(|_| "pin_admin_fallback_secret_key_123".to_string());

    let admin_state = AdminState {
        store: store.clone(),
        jinja_env,
        jwt_secret,
        scheduler: scheduler.clone(),
    };

    let app_state = Arc::new(AppState {
        store,
        matrix_auth,
        scheduler,
        forwarder,
    });

    // 8. Build Axum Router
    let app = Router::new()
        .route("/health", get(health))
        .route("/waitlist", post(waitlist))
        .route("/schedule/register", post(schedule_register))
        .route("/schedule/cancel", post(schedule_cancel))
        .route("/push/register", post(push_register))
        .route("/push/test", post(push_test))
        .route("/capability", post(capability_request))
        .route("/convert", post(convert))
        .route("/transcribe", post(transcribe))
        .route("/catalog", get(catalog))
        .route("/catalog/categories", get(catalog_categories))
        .route("/tool/:name", post(tool_call))
        .route("/infer", post(infer_call))
        .route("/debug/log", post(debug_log))
        // Admin UI routes
        .route("/admin/login", get(admin::login_page))
        .route("/admin/logout", post(admin::logout))
        .route("/admin/auth/google", get(admin::auth_google))
        .route("/admin/auth/google/callback", get(admin::auth_google_callback))
        .route("/admin", get(admin::dashboard))
        .route("/admin/tab/backlog", get(admin::tab_backlog))
        .route("/admin/capability/:id/status/:status", post(admin::set_backlog_status))
        .route("/admin/tab/push", get(admin::tab_push))
        .route("/admin/push/wake", post(admin::push_wake))
        .route("/admin/push/catalog", post(admin::push_catalog))
        .route("/admin/tab/store", get(admin::tab_store))
        .route("/admin/mcp/server/:server/refresh", post(admin::mcp_refresh))
        .route("/admin/mcp/server/:server/tools", get(admin::mcp_server_tools))
        .route("/admin/store/:name/toggle", post(admin::store_toggle))
        .route("/admin/store/:name", post(admin::store_save))
        .route("/admin/tab/waitlist", get(admin::tab_waitlist))
        .route("/admin/waitlist/poll", post(admin::waitlist_poll))
        .route("/admin/waitlist/:wid/thread", get(admin::waitlist_thread))
        .route("/admin/waitlist/:wid/preview", get(admin::waitlist_preview))
        .route("/admin/waitlist/:wid/send", post(admin::waitlist_send))
        .route("/admin/waitlist/send-unsent", post(admin::waitlist_send_unsent))
        .route("/admin/assistant/install", post(admin::install_assistant))
        .route("/admin/tab/:tab", get(admin::tab_generic))
        .with_state(admin_state)
        .layer(tower_http::trace::TraceLayer::new_for_http())
        // App state layer (for API handlers)
        .layer(axum::Extension(app_state));

    // 9. Start Axum Server
    let host = std::env::var("PIN_PROXY_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port = std::env::var("PIN_PROXY_PORT").unwrap_or_else(|_| "8088".to_string());
    let addr = format!("{}:{}", host, port);
    
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("Pin Unified Backend listening on http://{}", addr);
    axum::serve(listener, app).await?;

    Ok(())
}

// ---- API Handlers ----

async fn health() -> impl IntoResponse {
    Json(json!({ "ok": true }))
}

// Public Waitlist Signups (rate-limited / honey-pot guarded in python)
// For rate limiting we keep a simple in-memory list (same as python's Ponytail method)
static WL_LIMITS: std::sync::Mutex<Option<HashMap<String, Vec<Instant>>>> = std::sync::Mutex::new(None);

async fn waitlist(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    // 1. Honeypot check
    if let Some(hp) = body.get("hp").and_then(|v| v.as_str()) {
        if !hp.trim().is_empty() {
            return Json(json!({ "ok": true })).into_response(); // silent success for bots
        }
    }

    // 2. IP rate limit check
    let ip = headers.get("cf-connecting-ip")
        .or_else(|| headers.get("x-forwarded-for"))
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.split(',').next())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let now = Instant::now();
    {
        let mut limits_guard = WL_LIMITS.lock().unwrap();
        let limits = limits_guard.get_or_init(HashMap::new);
        
        let hits = limits.entry(ip).or_default();
        // retain last 1 hour
        hits.retain(|&t| now.duration_since(t).as_secs() < 3600);
        
        if hits.len() >= 5 {
            return (StatusCode::TOO_MANY_REQUESTS, "too many requests").into_response();
        }
        hits.push(now);
    }

    // 3. Email validation
    let email = body.get("email").and_then(|v| v.as_str()).unwrap_or("").trim();
    if !email.contains('@') || email.len() < 5 {
        return (StatusCode::UNPROCESSABLE_ENTITY, "invalid email").into_response();
    }

    let use_case = body.get("use").and_then(|v| v.as_str()).unwrap_or("");
    let use_trimmed = if use_case.len() > 200 { &use_case[..200] } else { use_case };

    let _ = state.store.add_waitlist(email, use_trimmed, "site").await;
    Json(json!({ "ok": true })).into_response()
}

// Scheduler handlers

async fn schedule_register(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    let user_id = match state.matrix_auth.check_token(auth).await {
        Ok(uid) => uid,
        Err((code, msg)) => return (code, msg).into_response(),
    };

    let job_id = match body.get("job_id").and_then(|v| v.as_str()) {
        Some(j) => j.to_string(),
        None => return (StatusCode::BAD_REQUEST, "missing job_id").into_response(),
    };
    let device = body.get("device").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let next_due = body.get("next_due").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let repeat = body.get("repeat").and_then(|v| v.as_str()).unwrap_or("once").to_string();
    let platform = body.get("platform").and_then(|v| v.as_str()).unwrap_or("apns").to_string();
    let interval_sec = body.get("interval_sec").and_then(|v| v.as_f64());

    state.scheduler.register(job_id, device.clone(), next_due, repeat, platform.clone(), interval_sec).await;
    let _ = state.store.record_push_device(&user_id, &device, &platform).await;

    Json(json!({ "ok": true })).into_response()
}

async fn push_register(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    let user_id = match state.matrix_auth.check_token(auth).await {
        Ok(uid) => uid,
        Err((code, msg)) => return (code, msg).into_response(),
    };

    let device = body.get("device").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let platform = body.get("platform").and_then(|v| v.as_str()).unwrap_or("apns").to_string();

    let _ = state.store.record_push_device(&user_id, &device, &platform).await;
    Json(json!({ "ok": true })).into_response()
}

async fn push_test(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let device = body.get("device").and_then(|v| v.as_str()).unwrap_or("");
    let platform = body.get("platform").and_then(|v| v.as_str()).unwrap_or("apns");

    if device.is_empty() {
        return Json(json!({ "ok": false, "error": "no device" })).into_response();
    }

    match state.scheduler.push(device, "pushtest", platform, true).await {
        Ok(_) => Json(json!({ "ok": true })).into_response(),
        Err(e) => Json(json!({ "ok": false, "error": e.to_string() })).into_response(),
    }
}

async fn schedule_cancel(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let job_id = match body.get("job_id").and_then(|v| v.as_str()) {
        Some(j) => j,
        None => return (StatusCode::BAD_REQUEST, "missing job_id").into_response(),
    };

    Json(json!({ "ok": state.scheduler.cancel(job_id).await })).into_response()
}

async fn capability_request(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    let user_id = match state.matrix_auth.check_token(auth).await {
        Ok(uid) => uid,
        Err((code, msg)) => return (code, msg).into_response(),
    };

    let cap = body.get("capability").and_then(|v| v.as_str()).unwrap_or("");
    let detail = body.get("detail").and_then(|v| v.as_str()).unwrap_or("");

    let _ = state.store.add_capability_request(cap, detail, &user_id).await;
    Json(json!({ "ok": true })).into_response()
}

// File Conversion Handler
async fn convert(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    mut multipart: Multipart
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let mut data = Vec::new();
    let mut filename = String::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        if field.name() == Some("file") {
            filename = field.file_name().unwrap_or("file").to_string();
            if let Ok(bytes) = field.bytes().await {
                data = bytes.to_vec();
            }
        }
    }

    if data.is_empty() {
        return Json(json!({ "markdown": "", "error": "ไม่มีไฟล์อัปโหลด" })).into_response();
    }

    match converter::convert_file(&data, &filename) {
        Ok(val) => Json(val).into_response(),
        Err(e) => Json(json!({ "markdown": "", "error": format!("แปลงไฟล์ไม่ได้: {}", e) })).into_response(),
    }
}

// Audio Transcription Handler
async fn transcribe(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    mut multipart: Multipart
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let mut data = Vec::new();
    let mut filename = String::new();
    let mut mime_type = None;

    while let Ok(Some(field)) = multipart.next_field().await {
        if field.name() == Some("file") {
            filename = field.file_name().unwrap_or("file").to_string();
            mime_type = field.content_type().map(|s| s.to_string());
            if let Ok(bytes) = field.bytes().await {
                data = bytes.to_vec();
            }
        }
    }

    if data.is_empty() {
        return Json(json!({ "text": "", "error": "ไม่มีไฟล์อัปโหลด" })).into_response();
    }

    match state.forwarder.transcribe(Some(&filename), mime_type.as_deref(), &data).await {
        Ok(text) => Json(json!({ "text": text })).into_response(),
        Err(e) => Json(json!({ "text": "", "error": format!("ถอดเสียงไม่ได้: {}", e) })).into_response(),
    }
}

// Debug Bot sink (Logs to ~/pin-debug.log)
async fn debug_log(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(mut body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64();
    if let Some(obj) = body.as_object_mut() {
        obj.insert("ts".to_string(), json!(now));
    }

    let payload_str = body.to_string();
    tracing::info!("Client debug log: {}", payload_str);
    let _ = state.store.insert_client_log(now, &payload_str).await;

    Json(json!({ "ok": true })).into_response()
}

// Catalog Manifest List
async fn catalog(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let mut tools = Vec::new();
    
    // Add enabled tools
    if let Ok(mut h_tools) = state.store.enabled_hosted_tools().await {
        tools.append(&mut h_tools);
    }
    if let Ok(mut m_tools) = state.store.enabled_mcp_tools().await {
        tools.append(&mut m_tools);
    }
    if let Ok(mut skills) = state.store.enabled_skills().await {
        tools.append(&mut skills);
    }
    if let Ok(mut subagents) = state.store.enabled_subagents().await {
        tools.append(&mut subagents);
    }
    
    let mut assistants = Vec::new();
    if let Ok(mut a) = state.store.enabled_assistants().await {
        assistants.append(&mut a);
    }

    // Enrich displaycopy
    let enriched_tools: Vec<Value> = tools.into_iter().map(display::enrich).collect();

    Json(json!({
        "tools": enriched_tools,
        "assistants": assistants
    })).into_response()
}

async fn catalog_categories(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    let mut tools = Vec::new();
    if let Ok(mut h_tools) = state.store.enabled_hosted_tools().await { tools.append(&mut h_tools); }
    if let Ok(mut m_tools) = state.store.enabled_mcp_tools().await { tools.append(&mut m_tools); }
    if let Ok(mut skills) = state.store.enabled_skills().await { tools.append(&mut skills); }
    if let Ok(mut subagents) = state.store.enabled_subagents().await { tools.append(&mut subagents); }

    let mut counts = HashMap::new();
    for t in tools {
        let enriched = display::enrich(t);
        let tier = enriched.get("pricing").and_then(|p| p.get("tier").and_then(|t| t.as_str())).unwrap_or("free");
        if tier == "free" {
            continue;
        }
        let cat = enriched.get("category").and_then(|v| v.as_str()).unwrap_or("อื่น ๆ").to_string();
        *counts.entry(cat).or_insert(0) += 1;
    }

    let mut ordered: Vec<(String, i32)> = counts.into_iter().collect();
    ordered.sort_by(|a, b| b.1.cmp(&a.1)); // Sort by count descending

    let categories: Vec<Value> = ordered.into_iter()
        .map(|(k, v)| json!({ "id": k, "label": k, "count": v }))
        .collect();

    Json(json!({ "categories": categories })).into_response()
}

// Call hosted / MCP tools
async fn tool_call(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Path(name): Path<String>,
    Json(args): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    let user_id = match state.matrix_auth.check_token(auth).await {
        Ok(uid) => uid,
        Err((code, msg)) => return (code, msg).into_response(),
    };

    // 0. Is it a built-in Native Tool?
    if let Some(res) = handle_native_tool(&name, &args).await {
        let _ = state.store.log_tool(&name, "native", &args.as_object().map_or(vec![], |o| o.keys().cloned().collect()), "call").await;
        return Json(res).into_response();
    }

    // 1. Is it an MCP tool?
    let mcp_idx = state.store.mcp_index().await.unwrap_or_default();
    if mcp_idx.contains_key(&name) {
        let _ = state.store.log_tool(&name, "mcp", &args.as_object().map_or(vec![], |o| o.keys().cloned().collect()), "call").await;
        if let Some(entry) = mcp_idx.get(&name) {
            return Json(mcp::call(entry, &name, args, Some(&user_id)).await).into_response();
        }
        return Json(json!({ "text": "เรียกเครื่องมือ MCP ไม่สำเร็จ" })).into_response();
    }

    // 2. Is it a dev-hosted remote tool?
    if let Ok(Some(endpoint)) = state.store.remote_endpoint(&name).await {
        let _ = state.store.log_tool(&name, "remote", &args.as_object().map_or(vec![], |o| o.keys().cloned().collect()), "call").await;
        let client = reqwest::Client::new();
        match client.post(&endpoint).json(&args).send().await {
            Ok(res) => {
                if let Ok(json_body) = res.json::<Value>().await {
                    Json(json_body).into_response()
                } else {
                    Json(json!({ "text": "เครื่องมือภายนอกส่งข้อมูลกลับมาผิดฟอร์แมต" })).into_response()
                }
            }
            Err(e) => Json(json!({ "text": format!("เครื่องมือภายนอกมีปัญหา: {:?}", e) })).into_response()
        }
    } else {
        // 3. Fallback mock remote tools
        let _ = state.store.log_tool(&name, "?", &args.as_object().map_or(vec![], |o| o.keys().cloned().collect()), "404").await;
        (StatusCode::NOT_FOUND, format!("no tool '{}'", name)).into_response()
    }
}

// Inference (Gemini/OpenRouter router)
async fn infer_call(
    axum::Extension(state): axum::Extension<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>
) -> Response {
    let auth = headers.get("authorization").and_then(|h| h.to_str().ok());
    if let Err((code, msg)) = state.matrix_auth.check_token(auth).await {
        return (code, msg).into_response();
    }

    state.forwarder.infer(headers, body).await
}

// Helper block for OnceLock initialization
trait OnceLockExt<T> {
    fn get_or_init<F>(&mut self, f: F) -> &mut T
    where
        F: FnOnce() -> T;
}

// --- Native Tools Implementation ---

async fn execute_web_search(args: &Value) -> Value {
    let query = args.get("query").and_then(|v| v.as_str()).unwrap_or("").trim();
    if query.is_empty() {
        return json!({"text": "ไม่มีคำค้น"});
    }
    let key = match std::env::var("SERPER_API_KEY") {
        Ok(k) if !k.is_empty() => k,
        _ => return json!({"text": "ค้นไม่ได้ตอนนี้ (ไม่มี API Key)"}),
    };

    let client = reqwest::Client::builder()
        .local_address(Some("0.0.0.0".parse().unwrap()))
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .unwrap_or_default();

    let body = json!({"q": query, "gl": "th", "hl": "th", "num": 6});
    let res = client.post("https://google.serper.dev/search")
        .header("X-API-KEY", key)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await;

    match res {
        Ok(r) => {
            if let Ok(data) = r.json::<Value>().await {
                let mut lines = Vec::new();
                if let Some(ab) = data.get("answerBox") {
                    let ans = ab.get("answer").or(ab.get("snippet")).and_then(|v| v.as_str()).unwrap_or("").trim();
                    if !ans.is_empty() {
                        lines.push(format!("คำตอบ: {}", ans));
                    }
                }
                if let Some(organic) = data.get("organic").and_then(|v| v.as_array()) {
                    for x in organic.iter().take(6) {
                        let title = x.get("title").and_then(|v| v.as_str()).unwrap_or("").trim();
                        let snip = x.get("snippet").and_then(|v| v.as_str()).unwrap_or("").trim();
                        let url = x.get("link").and_then(|v| v.as_str()).unwrap_or("").trim();
                        lines.push(format!("• {}\n  {}\n  {}", title, snip, url));
                    }
                }
                if lines.is_empty() {
                    json!({"text": "ไม่พบข้อมูล"})
                } else {
                    json!({"text": format!("ผลค้นหาเว็บ:\n{}", lines.join("\n"))})
                }
            } else {
                json!({"text": "ค้นไม่ได้ตอนนี้ (ข้อมูลไม่ถูกต้อง)"})
            }
        },
        Err(_) => json!({"text": "ค้นไม่ได้ตอนนี้"}),
    }
}

async fn execute_generate_image(args: &Value) -> Value {
    let prompt = args.get("prompt").and_then(|v| v.as_str()).unwrap_or("").trim();
    if prompt.is_empty() {
        return json!({"text": "อยากให้วาดอะไรบอกได้เลยค่ะ"});
    }
    let enc = urlencoding::encode(prompt);
    let url = format!("https://image.pollinations.ai/prompt/{}?width=1024&height=1024&nologo=true", enc);
    let img = format!("<img src=\"{}\" alt=\"generated\" style=\"width:100%;border-radius:12px;display:block\"/>", url);
    json!({
        "flex": {
            "header": {"icon": "sparkles", "title": "รูปที่วาดให้"},
            "body": [{"type": "html", "html": img}]
        }
    })
}

async fn execute_currency(args: &Value) -> Value {
    let base = args.get("base").and_then(|v| v.as_str()).unwrap_or("USD").trim().to_uppercase();
    let quote = args.get("quote").and_then(|v| v.as_str()).unwrap_or("THB").trim().to_uppercase();
    
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(10)).build().unwrap_or_default();
    let url = format!("https://api.frankfurter.dev/v1/latest?base={}&symbols={}", base, quote);
    
    match client.get(&url).send().await {
        Ok(r) => {
            if let Ok(data) = r.json::<Value>().await {
                if let Some(rates) = data.get("rates").and_then(|v| v.as_object()) {
                    if let Some(val) = rates.get(&quote).and_then(|v| v.as_f64()) {
                        return json!({
                            "flex": {
                                "header": {"icon": "money", "title": format!("{} → {}", base, quote)},
                                "body": [
                                    {"type": "bignum", "value": format!("{:.4}", val), "sub": format!("1 {} = {:.4} {}", base, val, quote)}
                                ]
                            }
                        });
                    }
                }
            }
            json!({"text": format!("ดึงค่าเงิน {}/{} ไม่ได้", base, quote)})
        },
        Err(_) => json!({"text": "ดึงข้อมูลค่าเงินไม่ได้"})
    }
}

async fn execute_weather(args: &Value) -> Value {
    let place = args.get("place").and_then(|v| v.as_str()).unwrap_or("กรุงเทพ").trim();
    let days = args.get("days").and_then(|v| v.as_i64()).unwrap_or(1).clamp(1, 7);
    
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(15)).build().unwrap_or_default();
    let geo_url = format!("https://geocoding-api.open-meteo.com/v1/search?name={}&count=1&language=th", urlencoding::encode(place));
    
    let (lat, lon, name) = match client.get(&geo_url).send().await {
        Ok(r) => {
            if let Ok(data) = r.json::<Value>().await {
                if let Some(hits) = data.get("results").and_then(|v| v.as_array()) {
                    if let Some(first) = hits.first() {
                        let lat = first.get("latitude").and_then(|v| v.as_f64()).unwrap_or(13.75);
                        let lon = first.get("longitude").and_then(|v| v.as_f64()).unwrap_or(100.5167);
                        let n = first.get("name").and_then(|v| v.as_str()).unwrap_or(place).to_string();
                        (lat, lon, n)
                    } else {
                        return json!({"text": format!("หาเมือง “{}” ไม่เจอ", place)});
                    }
                } else {
                    return json!({"text": format!("หาเมือง “{}” ไม่เจอ", place)});
                }
            } else {
                return json!({"text": format!("หาเมือง “{}” ไม่เจอ", place)});
            }
        },
        Err(_) => return json!({"text": "เชื่อมต่อเซิร์ฟเวอร์ไม่ได้"})
    };

    let fc_url = format!("https://api.open-meteo.com/v1/forecast?latitude={}&longitude={}&timezone=Asia/Bangkok&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&forecast_days={}", lat, lon, days);
    match client.get(&fc_url).send().await {
        Ok(r) => {
            if let Ok(data) = r.json::<Value>().await {
                if let Some(daily) = data.get("daily") {
                    let dates = daily.get("time").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                    let t_max = daily.get("temperature_2m_max").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                    let t_min = daily.get("temperature_2m_min").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                    let pop = daily.get("precipitation_probability_max").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                    
                    let mut cards = Vec::new();
                    let day_labels = ["วันนี้", "พรุ่งนี้"];
                    for i in 0..dates.len() {
                        let label = if i < day_labels.len() {
                            day_labels[i].to_string()
                        } else {
                            let d_str = dates[i].as_str().unwrap_or("");
                            if d_str.len() > 5 { d_str[5..].replace("-", "/") } else { d_str.to_string() }
                        };
                        
                        let mx = t_max.get(i).and_then(|v| v.as_f64()).unwrap_or(0.0);
                        let mn = t_min.get(i).and_then(|v| v.as_f64()).unwrap_or(0.0);
                        let rain = pop.get(i).and_then(|v| v.as_i64()).unwrap_or(0);
                        
                        cards.push(json!({
                            "header": {"icon": "fx", "title": format!("{} · {}", name, label)},
                            "body": [
                                {"type": "bignum", "value": format!("{:.0}°", mx), "sub": format!("ต่ำสุด {:.0}°", mn)},
                                {"type": "text", "text": format!("โอกาสฝน {}%", rain)}
                            ]
                        }));
                    }
                    if cards.is_empty() {
                        return json!({"text": format!("ดึงอากาศ {} ไม่ได้", name)});
                    }
                    if cards.len() == 1 {
                        return json!({"flex": cards[0]});
                    }
                    return json!({
                        "flex": {
                            "direction": "horizontal",
                            "cards": cards
                        }
                    });
                }
            }
            json!({"text": format!("ดึงอากาศ {} ไม่ได้", name)})
        },
        Err(_) => json!({"text": "ดึงข้อมูลอากาศไม่ได้"})
    }
}

async fn handle_native_tool(name: &str, args: &Value) -> Option<Value> {
    match name {
        "web_search" => Some(execute_web_search(args).await),
        "get_weather" => Some(execute_weather(args).await),
        "get_currency" => Some(execute_currency(args).await),
        "generate_image" => Some(execute_generate_image(args).await),
        _ => None,
    }
}


impl<T> OnceLockExt<T> for Option<T> {
    fn get_or_init<F>(&mut self, f: F) -> &mut T
    where
        F: FnOnce() -> T
    {
        if self.is_none() {
            *self = Some(f());
        }
        self.as_mut().unwrap()
    }
}
