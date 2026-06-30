use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use std::path::PathBuf;
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use axum::body::Body;
use serde::{Serialize, Deserialize};
use serde_json::{json, Value};
use jsonwebtoken::{encode, Header, EncodingKey, Algorithm};
use tracing::{info, warn, error};

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

    pub async fn check_token(&self, authorization: Option<&str>) -> Result<String, (axum::http::StatusCode, &'static str)> {
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
        let res = match client.get(&url)
            .header("Authorization", format!("Bearer {}", token))
            .send()
            .await 
        {
            Ok(r) => r,
            Err(_) => return Err((axum::http::StatusCode::SERVICE_UNAVAILABLE, "auth backend unreachable")),
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
            cache.insert(token.to_string(), AuthCacheEntry {
                user_id: user_id.clone(),
                expires_at: Instant::now() + std::time::Duration::from_secs(self.ttl_secs),
            });
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

    pub fn project_id(&self) -> &str {
        &self.fcm_project_id
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
        let token_url = sa["token_uri"].as_str().unwrap_or("https://oauth2.googleapis.com/token");

        #[derive(Serialize)]
        struct GoogleClaims {
            iss: String,
            scope: String,
            aud: String,
            exp: u64,
            iat: u64,
        }

        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
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
        let res = client.post(token_url)
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

    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
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

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Job {
    pub device: String,
    pub next_due: f64,
    pub repeat: String,
    pub platform: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interval_sec: Option<f64>,
}

pub struct Scheduler {
    store_path: PathBuf,
    jobs: RwLock<HashMap<String, Job>>,
    google_auth: Arc<GoogleAuth>,
}

impl Scheduler {
    pub fn new(store_path: PathBuf, google_auth: Arc<GoogleAuth>) -> Self {
        let mut jobs = HashMap::new();
        if store_path.exists() {
            if let Ok(raw) = std::fs::read_to_string(&store_path) {
                if let Ok(loaded) = serde_json::from_str(&raw) {
                    jobs = loaded;
                }
            }
        }
        Self {
            store_path,
            jobs: RwLock::new(jobs),
            google_auth,
        }
    }

    fn save(&self) {
        let jobs = self.jobs.read().unwrap();
        if let Ok(raw) = serde_json::to_string(&*jobs) {
            let _ = std::fs::write(&self.store_path, raw);
        }
    }

    pub fn register(&self, job_id: String, device: String, next_due: f64, repeat: String, platform: String, interval_sec: Option<f64>) {
        let job = Job {
            device,
            next_due,
            repeat,
            platform,
            interval_sec,
        };
        let mut jobs = self.jobs.write().unwrap();
        jobs.insert(job_id, job);
        drop(jobs);
        self.save();
    }

    pub fn cancel(&self, job_id: &str) -> bool {
        let mut jobs = self.jobs.write().unwrap();
        let ok = jobs.remove(job_id).is_some();
        drop(jobs);
        if ok {
            self.save();
        }
        ok
    }

    pub fn list_for(&self, device: &str) -> Vec<Value> {
        let jobs = self.jobs.read().unwrap();
        jobs.iter()
            .filter(|(_, j)| j.device == device)
            .map(|(jid, j)| json!({
                "job_id": jid,
                "device": j.device,
                "next_due": j.next_due,
                "repeat": j.repeat,
                "platform": j.platform,
                "interval_sec": j.interval_sec,
            }))
            .collect()
    }

    pub async fn push(&self, device: &str, job_id: &str, platform: &str, force: bool) -> Result<(), Box<dyn std::error::Error>> {
        if platform == "fcm" {
            self.push_fcm(device, job_id, force).await
        } else {
            self.push_apns(device, job_id, force).await
        }
    }

    async fn push_fcm(&self, device: &str, job_id: &str, force: bool) -> Result<(), Box<dyn std::error::Error>> {
        let token = self.google_auth.get_access_token().await;
        if token.is_none() {
            warn!("[sched] would FCM push job={} device={} (no SA credentials)", job_id, &device[..device.len().min(8)]);
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
        let res = client.post(format!("https://fcm.googleapis.com/v1/projects/{}/messages:send", project))
            .header("Authorization", format!("Bearer {}", token))
            .json(&msg)
            .send()
            .await?;

        info!("[sched] fcm job={} status={}", job_id, res.status());
        Ok(())
    }

    async fn push_apns(&self, device: &str, job_id: &str, force: bool) -> Result<(), Box<dyn std::error::Error>> {
        let jwt_token = apns_jwt();
        if jwt_token.is_none() {
            warn!("[sched] would APNs push job={} device={} (no APNs credentials)", job_id, &device[..device.len().min(8)]);
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
        let client = reqwest::Client::builder()
            .build()?;
        
        let res = client.post(format!("https://{}/3/device/{}", host, device))
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
        let mut jobs_to_fire = Vec::new();
        
        // Find due jobs
        {
            let jobs = self.jobs.read().unwrap();
            for (jid, j) in jobs.iter() {
                if j.next_due <= now {
                    jobs_to_fire.push((jid.clone(), j.clone()));
                }
            }
        }

        for (jid, j) in jobs_to_fire {
            if let Err(e) = self.push(&j.device, &jid, &j.platform, false).await {
                error!("[sched] push failed for job {}: {:?}", jid, e);
            }

            let mut jobs = self.jobs.write().unwrap();
            if let Some(job) = jobs.get_mut(&jid) {
                if let Some(iv) = job.interval_sec {
                    if iv > 0.0 {
                        job.next_due += iv;
                    } else if job.repeat == "daily" {
                        job.next_due += 86400.0;
                    } else {
                        jobs.remove(&jid);
                    }
                } else if job.repeat == "daily" {
                    job.next_due += 86400.0;
                } else {
                    jobs.remove(&jid);
                }
            }
        }
        self.save();
    }
}

// --- LLM Forwarder & Proxies ---

pub struct LLMForwarder {
    free_model: String,
    embed_model: String,
    embed_dim: usize,
}

impl LLMForwarder {
    pub fn new(free_model: String, embed_model: String, embed_dim: usize) -> Self {
        Self {
            free_model,
            embed_model,
            embed_dim,
        }
    }

    pub async fn infer(&self, headers: HeaderMap, body: Value) -> Response {
        let x_pin_tier = headers.get("x-pin-tier")
            .and_then(|h| h.to_str().ok())
            .unwrap_or("free");
        let x_openrouter_key = headers.get("x-openrouter-key")
            .and_then(|h| h.to_str().ok());
        let x_openrouter_referer = headers.get("x-openrouter-referer")
            .and_then(|h| h.to_str().ok());

        let url: String;
        let mut client_headers = reqwest::header::HeaderMap::new();

        let payload = if x_pin_tier == "paid" {
            let key = match x_openrouter_key {
                Some(k) => k,
                None => return (axum::http::StatusCode::BAD_REQUEST, "missing OpenRouter key").into_response(),
            };
            url = "https://openrouter.ai/api/v1/chat/completions".to_string();
            client_headers.insert("Authorization", format!("Bearer {}", key).parse().unwrap());
            if let Some(ref_val) = x_openrouter_referer {
                client_headers.insert("HTTP-Referer", ref_val.parse().unwrap());
            }
            body
        } else {
            let gkey = match std::env::var("GEMINI_API_KEY") {
                Ok(k) if !k.is_empty() => k,
                _ => return (axum::http::StatusCode::SERVICE_UNAVAILABLE, "proxy not configured").into_response(),
            };
            url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions".to_string();
            client_headers.insert("Authorization", format!("Bearer {}", gkey).parse().unwrap());
            
            // Inject free model if missing
            let mut payload = body;
            if payload.get("model").is_none() {
                if let Some(obj) = payload.as_object_mut() {
                    obj.insert("model".to_string(), json!(self.free_model));
                }
            }
            payload
        };

        // We bind to 0.0.0.0 to force IPv4 (same as AsyncHTTPTransport(local_address="0.0.0.0") in Python)
        let client = match reqwest::Client::builder()
            .local_address(Some("0.0.0.0".parse().unwrap()))
            .timeout(std::time::Duration::from_secs(90))
            .build() 
        {
            Ok(c) => c,
            Err(_) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, "failed to build HTTP client").into_response(),
        };

        let res = match client.post(&url)
            .headers(client_headers)
            .json(&payload)
            .send()
            .await 
        {
            Ok(r) => r,
            Err(e) => return (axum::http::StatusCode::BAD_GATEWAY, format!("provider error: {:?}", e)).into_response(),
        };

        let status = res.status();
        let content_type = res.headers().get("content-type").cloned();
        let bytes = match res.bytes().await {
            Ok(b) => b,
            Err(_) => return (axum::http::StatusCode::BAD_GATEWAY, "failed to read provider response").into_response(),
        };

        let mut builder = Response::builder().status(status);
        if let Some(ct) = content_type {
            builder = builder.header("content-type", ct);
        }
        builder.body(Body::from(bytes)).unwrap()
    }

    pub async fn embed(&self, body: Value) -> Response {
        let gkey = match std::env::var("GEMINI_API_KEY") {
            Ok(k) if !k.is_empty() => k,
            _ => return (axum::http::StatusCode::SERVICE_UNAVAILABLE, "proxy not configured").into_response(),
        };

        let payload = json!({
            "model": body.get("model").unwrap_or(&json!(self.embed_model)),
            "input": body.get("input").unwrap_or(&json!("")),
            "dimensions": body.get("dimensions").unwrap_or(&json!(self.embed_dim)),
        });

        let client = match reqwest::Client::builder()
            .local_address(Some("0.0.0.0".parse().unwrap()))
            .timeout(std::time::Duration::from_secs(30))
            .build() 
        {
            Ok(c) => c,
            Err(_) => return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, "failed to build HTTP client").into_response(),
        };

        let res = match client.post("https://generativelanguage.googleapis.com/v1beta/openai/embeddings")
            .header("Authorization", format!("Bearer {}", gkey))
            .json(&payload)
            .send()
            .await 
        {
            Ok(r) => r,
            Err(_) => return (axum::http::StatusCode::BAD_GATEWAY, "failed to contact provider").into_response(),
        };

        let status = res.status();
        let content_type = res.headers().get("content-type").cloned();
        let bytes = match res.bytes().await {
            Ok(b) => b,
            Err(_) => return (axum::http::StatusCode::BAD_GATEWAY, "failed to read provider response").into_response(),
        };

        let mut builder = Response::builder().status(status);
        if let Some(ct) = content_type {
            builder = builder.header("content-type", ct);
        }
        builder.body(Body::from(bytes)).unwrap()
    }

    pub async fn transcribe(&self, name: Option<&str>, mime_type: Option<&str>, data: &[u8]) -> Result<String, String> {
        let gkey = std::env::var("GEMINI_API_KEY")
            .map_err(|_| "proxy not configured".to_string())?;
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

        let url = format!("https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent", self.free_model);
        let res = client.post(&url)
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
        while !lines.is_empty() && (lines[0].trim().starts_with('#') || lines[0].to_lowercase().contains("transcript")) {
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
    let ext = name.unwrap_or("")
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
