use axum::body::Body;
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tracing::{error, info, warn};

// --- Matrix Auth Cache ---

struct AuthCacheEntry {
    user_id: String,
    expires_at: Instant,
}

pub struct MatrixAuth {
    homeserver: String,
    ttl_secs: u64,
    cache: RwLock<HashMap<String, AuthCacheEntry>>,
}

impl MatrixAuth {
    pub fn new(homeserver: String, ttl_secs: u64) -> Self {
        Self {
            homeserver,
            ttl_secs,
            cache: RwLock::new(HashMap::new()),
        }
    }

    pub async fn check_token(
        &self,
        authorization: Option<&str>,
    ) -> Result<String, (axum::http::StatusCode, &'static str)> {
        let token = match authorization {
            Some(auth) => {
                let stripped = auth.trim().trim_start_matches("Bearer ").trim();
                if stripped.is_empty() {
                    return Err((axum::http::StatusCode::UNAUTHORIZED, "unauthorized"));
                }
                stripped
            }
            None => return Err((axum::http::StatusCode::UNAUTHORIZED, "unauthorized")),
        };

        // Check cache
        {
            let cache = self.cache.read().unwrap();
            if let Some(entry) = cache.get(token) {
                if entry.expires_at > Instant::now() {
                    return Ok(entry.user_id.clone());
                }
            }
        }

        // Query homeserver
        let client = reqwest::Client::new();
        let url = format!("{}/_matrix/client/v3/account/whoami", self.homeserver);
        let res = match client
            .get(&url)
            .header("Authorization", format!("Bearer {}", token))
            .send()
            .await
        {
            Ok(r) => r,
            Err(_) => {
                return Err((
                    axum::http::StatusCode::SERVICE_UNAVAILABLE,
                    "auth backend unreachable",
                ))
            }
        };

        if res.status() != 200 {
            let mut cache = self.cache.write().unwrap();
            cache.remove(token);
            return Err((axum::http::StatusCode::UNAUTHORIZED, "unauthorized"));
        }

        #[derive(Deserialize)]
        struct WhoamiResponse {
            user_id: String,
        }

        if let Ok(body) = res.json::<WhoamiResponse>().await {
            let user_id = body.user_id;
            let mut cache = self.cache.write().unwrap();
            cache.insert(
                token.to_string(),
                AuthCacheEntry {
                    user_id: user_id.clone(),
                    expires_at: Instant::now() + std::time::Duration::from_secs(self.ttl_secs),
                },
            );
            Ok(user_id)
        } else {
            Err((axum::http::StatusCode::UNAUTHORIZED, "unauthorized"))
        }
    }
}

// --- Google FCM Access Token ---

struct FcmTokenCache {
    access_token: String,
    expires_at: Instant,
}

pub struct GoogleAuth {
    fcm_sa_path: Option<String>,
    fcm_project_id: String,
    cache: RwLock<Option<FcmTokenCache>>,
}

impl GoogleAuth {
    pub fn new(fcm_sa_path: Option<String>, fcm_project_id: String) -> Self {
        Self {
            fcm_sa_path,
            fcm_project_id,
            cache: RwLock::new(None),
        }
    }

    pub async fn get_access_token(&self) -> Option<String> {
        let sa_path = self.fcm_sa_path.as_ref()?;

        // Check cache
        {
            let cache = self.cache.read().unwrap();
            if let Some(c) = cache.as_ref() {
                if c.expires_at > Instant::now() + std::time::Duration::from_secs(60) {
                    return Some(c.access_token.clone());
                }
            }
        }

        // Mint a new token using Service Account JWT
        let raw = std::fs::read_to_string(sa_path).ok()?;
        let sa: Value = serde_json::from_str(&raw).ok()?;

        let client_email = sa["client_email"].as_str()?;
        let private_key_pem = sa["private_key"].as_str()?;
        let token_url = sa["token_uri"]
            .as_str()
            .unwrap_or("https://oauth2.googleapis.com/token");

        #[derive(Serialize)]
        struct GoogleClaims {
            iss: String,
            scope: String,
            aud: String,
            exp: u64,
            iat: u64,
        }

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let claims = GoogleClaims {
            iss: client_email.to_string(),
            scope: "https://www.googleapis.com/auth/firebase.messaging".to_string(),
            aud: token_url.to_string(),
            exp: now + 3600,
            iat: now,
        };

        let key = EncodingKey::from_rsa_pem(private_key_pem.as_bytes()).ok()?;
        let jwt = encode(&Header::new(Algorithm::RS256), &claims, &key).ok()?;

        let client = reqwest::Client::new();
        let res = client
            .post(token_url)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", &jwt),
            ])
            .send()
            .await
            .ok()?;

        #[derive(Deserialize)]
        struct TokenResponse {
            access_token: String,
            expires_in: u64,
        }

        if let Ok(body) = res.json::<TokenResponse>().await {
            let mut cache = self.cache.write().unwrap();
            *cache = Some(FcmTokenCache {
                access_token: body.access_token.clone(),
                expires_at: Instant::now() + std::time::Duration::from_secs(body.expires_in),
            });
            Some(body.access_token)
        } else {
            None
        }
    }
}

// --- APNs Helper ---

pub fn apns_jwt() -> Option<String> {
    let key_path = std::env::var("APNS_KEY_PATH").ok()?;
    let key_id = std::env::var("APNS_KEY_ID").ok()?;
    let team_id = std::env::var("APNS_TEAM_ID").ok()?;

    if key_path.is_empty() || key_id.is_empty() || team_id.is_empty() {
        return None;
    }

    let key_content = std::fs::read_to_string(key_path).ok()?;

    #[derive(Serialize)]
    struct ApnsClaims {
        iss: String,
        iat: u64,
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let claims = ApnsClaims {
        iss: team_id,
        iat: now,
    };

    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(key_id);

    let key = EncodingKey::from_ec_pem(key_content.as_bytes()).ok()?;
    encode(&header, &claims, &key).ok()
}

// --- Push Scheduler ---

pub struct Scheduler {
    store: crate::store::Store,
    google_auth: Arc<GoogleAuth>,
}

impl Scheduler {
    pub fn new(store: crate::store::Store, google_auth: Arc<GoogleAuth>) -> Self {
        Self { store, google_auth }
    }

    pub async fn register(
        &self,
        job_id: String,
        device: String,
        next_due: f64,
        repeat: String,
        platform: String,
        interval_sec: Option<f64>,
    ) {
        if let Err(e) = self
            .store
            .add_scheduled_job(&job_id, &device, next_due, &repeat, &platform, interval_sec)
            .await
        {
            error!("[sched] failed to register job {}: {:?}", job_id, e);
        }
    }

    pub async fn cancel(&self, job_id: &str) -> bool {
        self.store
            .remove_scheduled_job(job_id)
            .await
            .unwrap_or(false)
    }

    pub async fn push(
        &self,
        device: &str,
        job_id: &str,
        platform: &str,
        force: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if platform == "fcm" {
            self.push_fcm(device, job_id, force).await
        } else {
            self.push_apns(device, job_id, force).await
        }
    }

    async fn push_fcm(
        &self,
        device: &str,
        job_id: &str,
        force: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let token = self.google_auth.get_access_token().await;
        if token.is_none() {
            warn!(
                "[sched] would FCM push job={} device={} (no SA credentials)",
                job_id,
                &device[..device.len().min(8)]
            );
            return Ok(());
        }
        let token = token.unwrap();
        let project = &self.google_auth.fcm_project_id;

        let mut data = HashMap::new();
        data.insert("pin_job".to_string(), job_id.to_string());
        if force {
            data.insert("force".to_string(), "1".to_string());
        }

        let msg = json!({
            "message": {
                "token": device,
                "data": data,
                "android": {"priority": "high"},
            }
        });

        let client = reqwest::Client::new();
        let res = client
            .post(format!(
                "https://fcm.googleapis.com/v1/projects/{}/messages:send",
                project
            ))
            .header("Authorization", format!("Bearer {}", token))
            .json(&msg)
            .send()
            .await?;

        info!("[sched] fcm job={} status={}", job_id, res.status());
        Ok(())
    }

    async fn push_apns(
        &self,
        device: &str,
        job_id: &str,
        force: bool,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let jwt_token = apns_jwt();
        if jwt_token.is_none() {
            warn!(
                "[sched] would APNs push job={} device={} (no APNs credentials)",
                job_id,
                &device[..device.len().min(8)]
            );
            return Ok(());
        }
        let jwt_token = jwt_token.unwrap();

        let topic = std::env::var("APNS_TOPIC").unwrap_or_else(|_| "io.tokens2.pin".to_string());
        let env = std::env::var("APNS_ENV").unwrap_or_else(|_| "sandbox".to_string());
        let host = if env == "sandbox" {
            "api.sandbox.push.apple.com"
        } else {
            "api.push.apple.com"
        };

        let mut payload = json!({
            "aps": {"content-available": 1},
            "pin_job": job_id,
        });
        if force {
            payload["force"] = json!("1");
        }

        // Setup HTTP/2 client
        let client = reqwest::Client::builder().build()?;

        let res = client
            .post(format!("https://{}/3/device/{}", host, device))
            .header("authorization", format!("bearer {}", jwt_token))
            .header("apns-topic", topic)
            .header("apns-push-type", "background")
            .header("apns-priority", "5")
            .json(&payload)
            .send()
            .await?;

        info!("[sched] apns job={} status={}", job_id, res.status());
        Ok(())
    }

    pub async fn fire_due(&self, now: f64) {
        let due = match self.store.get_due_jobs(now).await {
            Ok(v) => v,
            Err(e) => {
                error!("[sched] failed to get due jobs: {:?}", e);
                return;
            }
        };

        for j in due {
            let jid = j["job_id"].as_str().unwrap_or("");
            let device = j["device"].as_str().unwrap_or("");
            let platform = j["platform"].as_str().unwrap_or("");
            let repeat = j["repeat"].as_str().unwrap_or("");
            let interval_sec = j["interval_sec"].as_f64();
            let mut next_due = j["next_due"].as_f64().unwrap_or(0.0);

            if let Err(e) = self.push(device, jid, platform, false).await {
                error!("[sched] push failed for job {}: {:?}", jid, e);
            }

            if let Some(iv) = interval_sec {
                if iv > 0.0 {
                    next_due += iv;
                    let _ = self.store.update_scheduled_job_due(jid, next_due).await;
                } else if repeat == "daily" {
                    next_due += 86400.0;
                    let _ = self.store.update_scheduled_job_due(jid, next_due).await;
                } else {
                    let _ = self.store.remove_scheduled_job(jid).await;
                }
            } else if repeat == "daily" {
                next_due += 86400.0;
                let _ = self.store.update_scheduled_job_due(jid, next_due).await;
            } else {
                let _ = self.store.remove_scheduled_job(jid).await;
            }
        }
    }
}

// --- LLM Forwarder & Proxies ---

pub struct LLMForwarder {
    free_model: String,
}

impl LLMForwarder {
    pub fn new(free_model: String) -> Self {
        Self { free_model }
    }

    pub async fn infer(&self, headers: HeaderMap, body: Value) -> Response {
        let x_pin_tier = headers
            .get("x-pin-tier")
            .and_then(|h| h.to_str().ok())
            .unwrap_or("free");
        let x_openrouter_key = headers
            .get("x-openrouter-key")
            .and_then(|h| h.to_str().ok());
        let x_openrouter_referer = headers
            .get("x-openrouter-referer")
            .and_then(|h| h.to_str().ok());

        // We bind to 0.0.0.0 to force IPv4 (same as AsyncHTTPTransport(local_address="0.0.0.0") in Python)
        let client = match reqwest::Client::builder()
            .local_address(Some("0.0.0.0".parse().unwrap()))
            .timeout(std::time::Duration::from_secs(90))
            .build()
        {
            Ok(c) => c,
            Err(_) => {
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    "failed to build HTTP client",
                )
                    .into_response()
            }
        };

        // Paid tier → OpenRouter passthrough (OpenAI-shaped both ways, BYO key).
        if x_pin_tier == "paid" {
            let key = match x_openrouter_key {
                Some(k) => k,
                None => {
                    return (
                        axum::http::StatusCode::BAD_REQUEST,
                        "missing OpenRouter key",
                    )
                        .into_response()
                }
            };
            let mut client_headers = reqwest::header::HeaderMap::new();
            client_headers.insert("Authorization", format!("Bearer {}", key).parse().unwrap());
            if let Some(ref_val) = x_openrouter_referer {
                client_headers.insert("HTTP-Referer", ref_val.parse().unwrap());
            }
            return forward_passthrough(
                &client,
                "https://openrouter.ai/api/v1/chat/completions",
                client_headers,
                &body,
            )
            .await;
        }

        // Free tier ("ปิ่น") → NATIVE Gemini generateContent. We go native rather
        // than the /openai/chat/completions compat endpoint so Gemini's built-in
        // features survive — most visibly summarizing a YouTube link, which the
        // OpenAI-shaped path drops (a URL is just text there). openai_to_gemini
        // detects YouTube URLs and attaches them as fileData parts so the model
        // actually watches the video; the response is mapped back to OpenAI shape
        // so the client (which speaks OpenAI for `pin`) needs no change.
        let gkey = match std::env::var("GEMINI_API_KEY") {
            Ok(k) if !k.is_empty() => k,
            _ => {
                return (
                    axum::http::StatusCode::SERVICE_UNAVAILABLE,
                    "proxy not configured",
                )
                    .into_response()
            }
        };
        let model = body
            .get("model")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(&self.free_model)
            .to_string();
        let gbody = openai_to_gemini(&body);
        let url = format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent",
            model
        );
        let res = match client
            .post(&url)
            .query(&[("key", gkey.as_str())])
            .json(&gbody)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                return (
                    axum::http::StatusCode::BAD_GATEWAY,
                    format!("provider error: {:?}", e),
                )
                    .into_response()
            }
        };
        let status = res.status();
        let raw = match res.bytes().await {
            Ok(b) => b,
            Err(_) => {
                return (
                    axum::http::StatusCode::BAD_GATEWAY,
                    "failed to read provider response",
                )
                    .into_response()
            }
        };
        // Pass upstream errors straight through so the client can surface them.
        if !status.is_success() {
            return Response::builder()
                .status(status)
                .header("content-type", "application/json")
                .body(Body::from(raw))
                .unwrap();
        }
        let gresp: Value = match serde_json::from_slice(&raw) {
            Ok(v) => v,
            Err(_) => {
                return (
                    axum::http::StatusCode::BAD_GATEWAY,
                    "invalid provider response",
                )
                    .into_response()
            }
        };
        let openai = gemini_to_openai(&gresp);
        Response::builder()
            .status(axum::http::StatusCode::OK)
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_vec(&openai).unwrap_or_default()))
            .unwrap()
    }

    pub async fn transcribe(
        &self,
        name: Option<&str>,
        mime_type: Option<&str>,
        data: &[u8],
    ) -> Result<String, String> {
        let gkey =
            std::env::var("GEMINI_API_KEY").map_err(|_| "proxy not configured".to_string())?;
        if gkey.is_empty() {
            return Err("proxy not configured".to_string());
        }

        let audio_mime = audio_mime(name, mime_type);
        let b64_data = base64::Engine::encode(&base64::prelude::BASE64_STANDARD, data);

        let payload = json!({
            "contents": [{
                "parts": [
                    {"text": "ถอดเสียงพูดต่อไปนี้เป็นข้อความ ตอบเฉพาะข้อความที่ได้ยิน ตามภาษาที่พูด ไม่ต้องอธิบายหรือเกริ่นนำ"},
                    {"inline_data": {
                        "mime_type": audio_mime,
                        "data": b64_data,
                    }}
                ]
            }]
        });

        let client = reqwest::Client::builder()
            .local_address(Some("0.0.0.0".parse().unwrap()))
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .map_err(|e| e.to_string())?;

        let url = format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent",
            self.free_model
        );
        let res = client
            .post(&url)
            .query(&[("key", &gkey)])
            .json(&payload)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if res.status() != 200 {
            return Err(format!("Google API returned status {}", res.status()));
        }

        let json_body = res.json::<Value>().await.map_err(|e| e.to_string())?;

        let parts = json_body["candidates"][0]["content"]["parts"]
            .as_array()
            .ok_or_else(|| "invalid response structure".to_string())?;

        let mut text = String::new();
        for p in parts {
            if let Some(t) = p.get("text").and_then(|v| v.as_str()) {
                text.push_str(t);
            }
        }
        let text = text.trim();

        // Strip headers
        let mut lines: Vec<&str> = text.lines().collect();
        while !lines.is_empty()
            && (lines[0].trim().starts_with('#') || lines[0].to_lowercase().contains("transcript"))
        {
            lines.remove(0);
        }

        let result = lines.join("\n").trim().to_string();
        if result.is_empty() {
            Ok(text.to_string())
        } else {
            Ok(result)
        }
    }
}

fn audio_mime(name: Option<&str>, ct: Option<&str>) -> String {
    let ext = name
        .unwrap_or("")
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase();
    match ext.as_str() {
        "m4a" | "mp4" => "audio/mp4".to_string(),
        "aac" => "audio/aac".to_string(),
        "wav" => "audio/wav".to_string(),
        "mp3" => "audio/mpeg".to_string(),
        "ogg" => "audio/ogg".to_string(),
        "flac" => "audio/flac".to_string(),
        _ => ct.unwrap_or("audio/mp4").to_string(),
    }
}

// ─────────────────── OpenAI ⇄ native Gemini adapters ───────────────────
// Rust port of lib/agent/llm_adapters.dart (openAiToGemini / geminiToOpenAi).
// Keep the two in sync: the device speaks OpenAI chat-completions for `pin`, so
// the proxy translates to Gemini's request shape and back. Tool-use must ride
// through both directions — the agent is tool-heavy.

/// Forward an OpenAI-shaped request to a compat endpoint, passing the response
/// bytes (and content-type) straight back. Used for the OpenRouter paid tier.
async fn forward_passthrough(
    client: &reqwest::Client,
    url: &str,
    client_headers: reqwest::header::HeaderMap,
    body: &Value,
) -> Response {
    let res = match client
        .post(url)
        .headers(client_headers)
        .json(body)
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_GATEWAY,
                format!("provider error: {:?}", e),
            )
                .into_response()
        }
    };
    let status = res.status();
    let content_type = res.headers().get("content-type").cloned();
    let bytes = match res.bytes().await {
        Ok(b) => b,
        Err(_) => {
            return (
                axum::http::StatusCode::BAD_GATEWAY,
                "failed to read provider response",
            )
                .into_response()
        }
    };
    let mut builder = Response::builder().status(status);
    if let Some(ct) = content_type {
        builder = builder.header("content-type", ct);
    }
    builder.body(Body::from(bytes)).unwrap()
}

/// OpenAI `arguments` (a JSON string) or an already-decoded object → object.
fn decode_args(v: Option<&Value>) -> Value {
    match v {
        Some(Value::String(s)) => serde_json::from_str(s).unwrap_or_else(|_| json!({})),
        Some(other) if other.is_object() => other.clone(),
        _ => json!({}),
    }
}

/// Strip JSON-Schema keywords Gemini's function schema rejects.
fn clean_schema(node: &Value) -> Value {
    match node {
        Value::Object(m) => {
            let mut out = serde_json::Map::new();
            for (k, val) in m {
                if k == "$schema" || k == "additionalProperties" || k == "default" {
                    continue;
                }
                out.insert(k.clone(), clean_schema(val));
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(a.iter().map(clean_schema).collect()),
        _ => node.clone(),
    }
}

fn gemini_fn_decl(fnv: &Value) -> Value {
    let mut decl = json!({ "name": fnv.get("name").cloned().unwrap_or_else(|| json!("")) });
    if let Some(d) = fnv.get("description") {
        decl["description"] = d.clone();
    }
    // Gemini rejects an empty-property object schema; omit params when none.
    if let Some(params) = fnv.get("parameters") {
        let has_props = params
            .get("properties")
            .and_then(|p| p.as_object())
            .map(|o| !o.is_empty())
            .unwrap_or(false);
        if has_props {
            decl["parameters"] = clean_schema(params);
        }
    }
    decl
}

/// Pull YouTube watch/short URLs out of free text (token scan — no regex dep).
fn youtube_urls(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for tok in text.split_whitespace() {
        // Trim wrapping punctuation but keep URL chars.
        let t = tok.trim_matches(|c: char| {
            !c.is_alphanumeric() && !matches!(c, ':' | '/' | '.' | '?' | '=' | '&' | '_' | '-')
        });
        let low = t.to_lowercase();
        let is_yt = low.contains("youtube.com/watch")
            || low.contains("youtu.be/")
            || low.contains("youtube.com/shorts");
        if is_yt && (low.starts_with("http://") || low.starts_with("https://")) {
            let s = t.to_string();
            if !out.contains(&s) {
                out.push(s);
            }
        }
    }
    out
}

/// OpenAI messages+tools → a Gemini `generateContent` request body.
fn openai_to_gemini(body: &Value) -> Value {
    let messages = body
        .get("messages")
        .and_then(|m| m.as_array())
        .cloned()
        .unwrap_or_default();
    let mut sys: Vec<String> = Vec::new();
    let mut contents: Vec<Value> = Vec::new();
    // Gemini's functionResponse needs the function NAME, but an OpenAI tool
    // message only carries tool_call_id → remember id→name from assistant turns.
    let mut id_to_name: HashMap<String, String> = HashMap::new();

    for m in &messages {
        let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("");
        if role == "system" {
            sys.push(
                m.get("content")
                    .and_then(|c| c.as_str())
                    .unwrap_or("")
                    .to_string(),
            );
            continue;
        }
        if role == "tool" {
            let id = m.get("tool_call_id").and_then(|v| v.as_str()).unwrap_or("");
            let name = id_to_name.get(id).cloned().unwrap_or_else(|| {
                m.get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("tool")
                    .to_string()
            });
            let content = m.get("content").and_then(|c| c.as_str()).unwrap_or("");
            contents.push(json!({
                "role": "user",
                "parts": [{"functionResponse": {"name": name, "response": {"result": content}}}]
            }));
            continue;
        }
        // user / assistant
        let mut parts: Vec<Value> = Vec::new();
        let mut text_buf = String::new();
        match m.get("content") {
            Some(Value::String(s)) if !s.is_empty() => {
                parts.push(json!({ "text": s }));
                text_buf.push_str(s);
            }
            Some(Value::Array(arr)) => {
                for p in arr {
                    if p.get("type").and_then(|t| t.as_str()) == Some("text") {
                        let t = p.get("text").and_then(|x| x.as_str()).unwrap_or("");
                        parts.push(json!({ "text": t }));
                        text_buf.push(' ');
                        text_buf.push_str(t);
                    }
                }
            }
            _ => {}
        }
        // Attach any YouTube URL in a user turn as a fileData part so native
        // Gemini watches the video instead of seeing a bare string.
        if role == "user" {
            for u in youtube_urls(&text_buf) {
                parts.push(json!({ "fileData": { "fileUri": u } }));
            }
        }
        if let Some(calls) = m.get("tool_calls").and_then(|c| c.as_array()) {
            for c in calls {
                let empty = json!({});
                let fnv = c.get("function").unwrap_or(&empty);
                let id = c.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let name = fnv.get("name").and_then(|v| v.as_str()).unwrap_or("");
                if !id.is_empty() {
                    id_to_name.insert(id.to_string(), name.to_string());
                }
                let args = decode_args(fnv.get("arguments"));
                parts.push(json!({ "functionCall": { "name": name, "args": args } }));
            }
        }
        if parts.is_empty() {
            continue;
        }
        let grole = if role == "assistant" { "model" } else { "user" };
        contents.push(json!({ "role": grole, "parts": parts }));
    }

    let mut b = json!({ "contents": contents });
    if !sys.is_empty() {
        b["systemInstruction"] = json!({ "parts": [{ "text": sys.join("\n\n") }] });
    }
    if let Some(tools) = body.get("tools").and_then(|t| t.as_array()) {
        let decls: Vec<Value> = tools
            .iter()
            .filter_map(|t| t.get("function"))
            .map(gemini_fn_decl)
            .collect();
        if !decls.is_empty() {
            b["tools"] = json!([{ "functionDeclarations": decls }]);
        }
    }
    b
}

/// A Gemini `generateContent` response → the OpenAI choices shape.
fn gemini_to_openai(resp: &Value) -> Value {
    let empty: Vec<Value> = Vec::new();
    let parts = resp
        .get("candidates")
        .and_then(|c| c.as_array())
        .and_then(|a| a.first())
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(|p| p.as_array())
        .unwrap_or(&empty);
    let mut buf = String::new();
    let mut tool_calls: Vec<Value> = Vec::new();
    for (i, p) in parts.iter().enumerate() {
        if let Some(t) = p.get("text").and_then(|x| x.as_str()) {
            buf.push_str(t);
        }
        if let Some(fc) = p.get("functionCall") {
            let name = fc.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let args = fc.get("args").cloned().unwrap_or_else(|| json!({}));
            tool_calls.push(json!({
                "id": format!("call_gm_{}", i),
                "type": "function",
                "function": { "name": name, "arguments": args.to_string() }
            }));
        }
    }
    let mut message = json!({
        "role": "assistant",
        "content": if buf.is_empty() { Value::Null } else { json!(buf) },
    });
    if !tool_calls.is_empty() {
        message["tool_calls"] = json!(tool_calls);
    }
    let mut out = json!({ "choices": [{ "message": message }] });
    if let Some(um) = resp.get("usageMetadata") {
        out["usage"] = json!({
            "prompt_tokens": um.get("promptTokenCount").and_then(|v| v.as_i64()).unwrap_or(0),
            "completion_tokens": um.get("candidatesTokenCount").and_then(|v| v.as_i64()).unwrap_or(0),
        });
    }
    out
}

#[cfg(test)]
mod adapter_tests {
    use super::*;

    #[test]
    fn youtube_url_becomes_filedata() {
        let body = json!({
            "messages": [{"role": "user", "content": "สรุปคลิปนี้ https://youtu.be/dQw4w9WgXcQ ให้หน่อย"}]
        });
        let g = openai_to_gemini(&body);
        let parts = g["contents"][0]["parts"].as_array().unwrap();
        // text part + fileData part
        assert!(parts.iter().any(|p| p.get("text").is_some()));
        let fd = parts
            .iter()
            .find_map(|p| p.get("fileData"))
            .expect("fileData part missing");
        assert_eq!(fd["fileUri"], "https://youtu.be/dQw4w9WgXcQ");
    }

    #[test]
    fn tool_call_roundtrips_to_openai() {
        let resp = json!({
            "candidates": [{"content": {"parts": [
                {"text": "ok"},
                {"functionCall": {"name": "get_weather", "args": {"city": "BKK"}}}
            ]}}]
        });
        let o = gemini_to_openai(&resp);
        let msg = &o["choices"][0]["message"];
        assert_eq!(msg["content"], "ok");
        let tc = &msg["tool_calls"][0];
        assert_eq!(tc["function"]["name"], "get_weather");
        // arguments must be a JSON *string* in OpenAI shape
        assert_eq!(tc["function"]["arguments"], "{\"city\":\"BKK\"}");
    }

    #[test]
    fn no_tools_key_when_empty() {
        let body = json!({ "messages": [{"role": "user", "content": "hi"}] });
        let g = openai_to_gemini(&body);
        assert!(g.get("tools").is_none());
    }
}
