use std::collections::HashMap;
use std::time::SystemTime;
use sqlx::{SqlitePool, Row};
use serde_json::{json, Value};
use crate::display;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS tools(
  name TEXT PRIMARY KEY, kind TEXT, description TEXT,
  parameters_json TEXT, arg_keys_json TEXT, source TEXT,
  enabled INTEGER DEFAULT 1, updated_at REAL,
  label TEXT, blurb TEXT, category TEXT, provider TEXT, pricing_json TEXT);
CREATE TABLE IF NOT EXISTS skills(
  name TEXT PRIMARY KEY, description TEXT, instructions TEXT,
  requires_json TEXT, enabled INTEGER DEFAULT 1, category TEXT, source TEXT);
CREATE TABLE IF NOT EXISTS subagents(
  name TEXT PRIMARY KEY, description TEXT, system TEXT,
  tool_names_json TEXT, model TEXT, max_steps INTEGER DEFAULT 6,
  category TEXT, source TEXT);
CREATE TABLE IF NOT EXISTS mcp_servers(
  name TEXT PRIMARY KEY, url TEXT, headers_json TEXT, status TEXT,
  category TEXT, source TEXT);
CREATE TABLE IF NOT EXISTS mcp_tools(
  server TEXT, name TEXT PRIMARY KEY, description TEXT,
  parameters_json TEXT, arg_keys_json TEXT, enabled INTEGER DEFAULT 1);
CREATE TABLE IF NOT EXISTS admin_users(
  email TEXT PRIMARY KEY, pw_hash TEXT, role TEXT);
CREATE TABLE IF NOT EXISTS tool_logs(
  ts REAL, tool TEXT, kind TEXT, arg_keys TEXT, status TEXT);
CREATE TABLE IF NOT EXISTS capability_requests(
  id INTEGER PRIMARY KEY AUTOINCREMENT, capability TEXT, detail TEXT,
  status TEXT DEFAULT 'requested', count INTEGER DEFAULT 1,
  requesters TEXT, created_at REAL, updated_at REAL);
CREATE TABLE IF NOT EXISTS waitlist(
  id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, use TEXT,
  source TEXT, created_at REAL, sent_at REAL, unsubscribed_at REAL);
CREATE TABLE IF NOT EXISTS mail_messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT, waitlist_email TEXT, direction TEXT,
  subject TEXT, body TEXT, msg_id TEXT, in_reply_to TEXT, created_at REAL);
CREATE TABLE IF NOT EXISTS push_devices(
  user_id TEXT PRIMARY KEY, device TEXT, platform TEXT, updated_at REAL);
CREATE TABLE IF NOT EXISTS client_logs(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, payload TEXT);
CREATE TABLE IF NOT EXISTS system_settings(
  key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS scheduled_jobs(
  job_id TEXT PRIMARY KEY, device TEXT, next_due REAL,
  repeat TEXT, platform TEXT, interval_sec REAL);
"#;

#[derive(Clone)]
pub struct Store {
    pub pool: SqlitePool,
}

impl Store {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn init(&self) -> Result<(), sqlx::Error> {
        // 1. Create tables
        sqlx::query("PRAGMA journal_mode=WAL").execute(&self.pool).await?;
        for stmt in SCHEMA.split(';') {
            let stmt = stmt.trim();
            if !stmt.is_empty() {
                sqlx::query(stmt).execute(&self.pool).await?;
            }
        }

        // 2. Run migrations (add columns if missing)
        let migrations = [
            ("tools", vec!["label", "blurb", "category", "provider", "pricing_json", "endpoint", "status", "config_json", "render", "ask_params"]),
            ("skills", vec!["label", "provider", "pricing_json", "category", "status"]),
            ("subagents", vec!["label", "provider", "pricing_json", "category", "status"]),
            ("mcp_tools", vec!["label", "category", "provider", "pricing_json", "defaults_json", "status", "render", "ask_params"]),
            ("waitlist", vec!["sent_at", "unsubscribed_at"]),
        ];

        for (tbl, cols) in migrations {
            for col in cols {
                if !self.has_column(tbl, col).await? {
                    let alter_query = format!("ALTER TABLE {} ADD COLUMN {} TEXT", tbl, col);
                    let _ = sqlx::query(&alter_query).execute(&self.pool).await;
                }
            }
        }

        // 3. Seed tools if empty
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tools")
            .fetch_one(&self.pool)
            .await?;
        if count == 0 {
            self.seed_tools().await?;
        }

        // 4. Seed MCP servers from env if empty
        let mcp_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM mcp_servers")
            .fetch_one(&self.pool)
            .await?;
        if mcp_count == 0 {
            if let Ok(raw_mcp) = std::env::var("PIN_MCP_SERVERS") {
                let _ = self.seed_mcp_from_json(&raw_mcp).await;
            }
        }

        // 5. Seed paid skills
        self.seed_paid_skills().await?;

        // Seed settings
        let settings_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM system_settings")
            .fetch_one(&self.pool)
            .await?;
        if settings_count == 0 {
            let free_model = std::env::var("PIN_FREE_MODEL").unwrap_or_else(|_| "gemini-flash-lite-latest".to_string());
            let embed_model = std::env::var("PIN_EMBED_MODEL").unwrap_or_else(|_| "gemini-embedding-001".to_string());
            let embed_dim = std::env::var("PIN_EMBED_DIM").unwrap_or_else(|_| "256".to_string());
            sqlx::query("INSERT INTO system_settings (key, value) VALUES (?, ?), (?, ?), (?, ?)")
                .bind("pin_free_model").bind(free_model)
                .bind("pin_embed_model").bind(embed_model)
                .bind("pin_embed_dim").bind(embed_dim)
                .execute(&self.pool).await?;
        }

        // Seed admins
        let admin_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM admin_users")
            .fetch_one(&self.pool)
            .await?;
        if admin_count == 0 {
            if let Ok(owners_env) = std::env::var("PIN_ADMIN_OWNERS") {
                for email in owners_env.split(',') {
                    let email = email.trim().to_lowercase();
                    if !email.is_empty() {
                        sqlx::query("INSERT OR IGNORE INTO admin_users (email, role) VALUES (?, 'owner')")
                            .bind(&email)
                            .execute(&self.pool).await?;
                    }
                }
            }
        }

        Ok(())
    }

    pub async fn get_setting(&self, key: &str) -> Result<Option<String>, sqlx::Error> {
        let val: Option<String> = sqlx::query_scalar("SELECT value FROM system_settings WHERE key = ?")
            .bind(key)
            .fetch_optional(&self.pool)
            .await?;
        Ok(val)
    }

    pub async fn set_setting(&self, key: &str, value: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO system_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            .bind(key)
            .bind(value)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn insert_client_log(&self, ts: f64, payload: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO client_logs (ts, payload) VALUES (?, ?)")
            .bind(ts)
            .bind(payload)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn is_admin(&self, email: &str) -> Result<bool, sqlx::Error> {
        let local = email.split('@').next().unwrap_or(email);
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM admin_users WHERE email = ? OR email = ?")
            .bind(email)
            .bind(local)
            .fetch_one(&self.pool)
            .await?;
        Ok(count > 0)
    }

    pub async fn add_scheduled_job(&self, job_id: &str, device: &str, next_due: f64, repeat: &str, platform: &str, interval_sec: Option<f64>) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT OR REPLACE INTO scheduled_jobs (job_id, device, next_due, repeat, platform, interval_sec) VALUES (?, ?, ?, ?, ?, ?)")
            .bind(job_id)
            .bind(device)
            .bind(next_due)
            .bind(repeat)
            .bind(platform)
            .bind(interval_sec)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn remove_scheduled_job(&self, job_id: &str) -> Result<bool, sqlx::Error> {
        let res = sqlx::query("DELETE FROM scheduled_jobs WHERE job_id = ?")
            .bind(job_id)
            .execute(&self.pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn get_scheduled_jobs_for_device(&self, device: &str) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT job_id, device, next_due, repeat, platform, interval_sec FROM scheduled_jobs WHERE device = ?")
            .bind(device)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.into_iter().map(|r| json!({
            "job_id": r.get::<String, _>("job_id"),
            "device": r.get::<String, _>("device"),
            "next_due": r.get::<f64, _>("next_due"),
            "repeat": r.get::<String, _>("repeat"),
            "platform": r.get::<String, _>("platform"),
            "interval_sec": r.get::<Option<f64>, _>("interval_sec"),
        })).collect())
    }

    pub async fn get_due_jobs(&self, now: f64) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT job_id, device, next_due, repeat, platform, interval_sec FROM scheduled_jobs WHERE next_due <= ?")
            .bind(now)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows.into_iter().map(|r| json!({
            "job_id": r.get::<String, _>("job_id"),
            "device": r.get::<String, _>("device"),
            "next_due": r.get::<f64, _>("next_due"),
            "repeat": r.get::<String, _>("repeat"),
            "platform": r.get::<String, _>("platform"),
            "interval_sec": r.get::<Option<f64>, _>("interval_sec"),
        })).collect())
    }

    pub async fn update_scheduled_job_due(&self, job_id: &str, next_due: f64) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE scheduled_jobs SET next_due = ? WHERE job_id = ?")
            .bind(next_due)
            .bind(job_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn has_column(&self, table: &str, column: &str) -> Result<bool, sqlx::Error> {
        let rows = sqlx::query(&format!("PRAGMA table_info({})", table))
            .fetch_all(&self.pool)
            .await?;
        for row in rows {
            let col_name: String = row.get("name");
            if col_name.eq_ignore_ascii_case(column) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    async fn seed_tools(&self) -> Result<(), sqlx::Error> {
        let now = now_secs();
        let seed_tools = vec![
            ("get_weather", "remote", "ดูพยากรณ์อากาศของเมืองที่ระบุ",
             json!({
                 "type": "object",
                 "properties": {
                     "place": {"type": "string", "description": "ชื่อเมือง"},
                     "days": {"type": "integer", "description": "จำนวนวัน 1-7"}
                 },
                 "required": ["place"]
             }),
             json!(["place", "days"])),
            ("get_currency", "remote", "ดูอัตราแลกเปลี่ยน เช่น USD/THB",
             json!({
                 "type": "object",
                 "properties": {
                     "base": {"type": "string", "description": "สกุลฐาน"},
                     "quote": {"type": "string", "description": "สกุลเทียบ"}
                 }
             }),
             json!(["base", "quote"])),
            ("web_search", "remote", "ค้นข้อมูลสด/ปัจจุบันจากเว็บ (ข่าว/ผลบอล/ราคา)",
             json!({
                 "type": "object",
                 "properties": {
                     "query": {"type": "string", "description": "คำค้น"}
                 },
                 "required": ["query"]
             }),
             json!(["query"])),
        ];

        let display_map = display::get_display();
        for (name, kind, desc, params, keys) in seed_tools {
            let d = display_map.get(name).cloned().unwrap_or(json!({}));
            sqlx::query(
                "INSERT INTO tools(name,kind,description,parameters_json,arg_keys_json,source,enabled,updated_at,label,blurb,category,provider,pricing_json) \
                 VALUES(?,?,?,?,?,?,1,?,?,?,?,?,?)"
            )
            .bind(name)
            .bind(kind)
            .bind(desc)
            .bind(params.to_string())
            .bind(keys.to_string())
            .bind("hosted")
            .bind(now)
            .bind(d.get("label").and_then(|v| v.as_str()))
            .bind(d.get("blurb").and_then(|v| v.as_str()))
            .bind(d.get("category").and_then(|v| v.as_str()))
            .bind(d.get("provider").and_then(|v| v.as_str()))
            .bind(d.get("pricing").map(|v| v.to_string()))
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    async fn seed_paid_skills(&self) -> Result<(), sqlx::Error> {
        let seed_paid = vec![
            json!({
                "name": "email_triage", "label": "คัดกรองอีเมล", "category": "เชื่อมบัญชี",
                "provider": "Google", "description": "สรุปเมลด่วน ร่างตอบให้",
                "pricing": {"tier": "subscription", "amount": 59, "currency": "THB", "period": "month"},
                "instructions": ""
            }),
            json!({
                "name": "line_assistant", "label": "ผู้ช่วยผ่าน LINE", "category": "เชื่อมบัญชี",
                "provider": "LINE", "description": "คุยกับปิ่นผ่าน LINE + เตือนเข้า LINE",
                "pricing": {"tier": "subscription", "amount": 39, "currency": "THB", "period": "month"},
                "instructions": ""
            }),
        ];

        for s in seed_paid {
            let name = s["name"].as_str().unwrap_or("");
            let desc = s["description"].as_str().unwrap_or("");
            let inst = s["instructions"].as_str().unwrap_or("");
            let cat = s["category"].as_str().unwrap_or("");
            let label = s["label"].as_str().unwrap_or("");
            let prov = s["provider"].as_str().unwrap_or("");
            let pricing = s["pricing"].to_string();

            sqlx::query(
                "INSERT OR IGNORE INTO skills(name,description,instructions,requires_json,enabled,category,source,label,provider,pricing_json) \
                 VALUES(?,?,?,?,1,?,?,?,?,?)"
            )
            .bind(name)
            .bind(desc)
            .bind(inst)
            .bind("{}")
            .bind(cat)
            .bind("hosted")
            .bind(label)
            .bind(prov)
            .bind(pricing)
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    async fn seed_mcp_from_json(&self, raw_mcp: &str) -> Result<(), sqlx::Error> {
        if let Ok(servers) = serde_json::from_str::<Vec<Value>>(raw_mcp) {
            for srv in servers {
                let name = srv["name"].as_str().unwrap_or("");
                let url = srv["url"].as_str().unwrap_or("");
                let headers = srv.get("headers").unwrap_or(&json!({})).to_string();

                sqlx::query(
                    "INSERT OR REPLACE INTO mcp_servers(name,url,headers_json,status,category,source) VALUES(?,?,?,?,?,?)"
                )
                .bind(name)
                .bind(url)
                .bind(headers)
                .bind("configured")
                .bind("")
                .bind("env")
                .execute(&self.pool)
                .await?;

                if let Some(tools) = srv.get("tools").and_then(|v| v.as_array()) {
                    for t in tools {
                        let t_name = t["name"].as_str().unwrap_or("");
                        let t_desc = t.get("description").and_then(|v| v.as_str()).unwrap_or("");
                        let t_params = t.get("parameters").unwrap_or(&json!({})).to_string();
                        let t_keys = t.get("argKeys").unwrap_or(&json!([])).to_string();

                        sqlx::query(
                            "INSERT OR REPLACE INTO mcp_tools(server,name,description,parameters_json,arg_keys_json,enabled) VALUES(?,?,?,?,?,1)"
                        )
                        .bind(name)
                        .bind(t_name)
                        .bind(t_desc)
                        .bind(t_params)
                        .bind(t_keys)
                        .execute(&self.pool)
                        .await?;
                    }
                }
            }
        }
        Ok(())
    }

    // ---- reads used by the catalog / MCP layers --------------------------------

    pub async fn enabled_hosted_tools(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM tools WHERE enabled=1 AND kind!='mcp'")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(self.tool_row_to_dict(r));
        }
        Ok(out)
    }

    pub async fn enabled_mcp_tools(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM mcp_tools WHERE enabled=1")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            let mut val = json!({
                "name": r.get::<String, _>("name"),
                "kind": "mcp",
                "description": r.get::<Option<String>, _>("description").unwrap_or_default(),
                "parameters": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("parameters_json").unwrap_or_default()).unwrap_or(json!({})),
                "argKeys": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("arg_keys_json").unwrap_or_default()).unwrap_or(json!([])),
                "server": r.get::<String, _>("server"),
            });
            self.enrich_row_metadata(&r, &mut val);
            out.push(val);
        }
        Ok(out)
    }

    pub async fn enabled_skills(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM skills WHERE enabled=1")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            let mut val = json!({
                "name": r.get::<String, _>("name"),
                "kind": "skill",
                "description": r.get::<Option<String>, _>("description").unwrap_or_default(),
                "instructions": r.get::<Option<String>, _>("instructions").unwrap_or_default(),
                "requires": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("requires_json").unwrap_or_default()).unwrap_or(json!({})),
            });
            self.enrich_row_metadata(&r, &mut val);
            out.push(val);
        }
        Ok(out)
    }

    pub async fn enabled_subagents(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM subagents")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            let mut val = json!({
                "name": r.get::<String, _>("name"),
                "kind": "subagent",
                "description": r.get::<Option<String>, _>("description").unwrap_or_default(),
                "system": r.get::<Option<String>, _>("system").unwrap_or_default(),
                "toolNames": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("tool_names_json").unwrap_or_default()).unwrap_or(json!([])),
                "model": r.get::<Option<String>, _>("model").unwrap_or_default(),
                "maxSteps": r.get::<i32, _>("max_steps"),
            });
            self.enrich_row_metadata(&r, &mut val);
            out.push(val);
        }
        Ok(out)
    }

    fn tool_row_to_dict(&self, r: sqlx::sqlite::SqliteRow) -> Value {
        let mut out = json!({
            "name": r.get::<String, _>("name"),
            "kind": r.get::<Option<String>, _>("kind").unwrap_or_default(),
            "description": r.get::<Option<String>, _>("description").unwrap_or_default(),
            "parameters": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("parameters_json").unwrap_or_default()).unwrap_or(json!({})),
            "argKeys": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("arg_keys_json").unwrap_or_default()).unwrap_or(json!([])),
        });

        if let Ok(label) = r.try_get::<String, _>("label") { if !label.is_empty() { out["label"] = json!(label); } }
        if let Ok(blurb) = r.try_get::<String, _>("blurb") { if !blurb.is_empty() { out["blurb"] = json!(blurb); } }
        if let Ok(category) = r.try_get::<String, _>("category") { if !category.is_empty() { out["category"] = json!(category); } }
        if let Ok(provider) = r.try_get::<String, _>("provider") { if !provider.is_empty() { out["provider"] = json!(provider); } }
        
        if let Ok(pricing_str) = r.try_get::<Option<String>, _>("pricing_json") {
            if let Some(p) = pricing_str.and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
                out["pricing"] = p;
            }
        }
        if let Ok(config_str) = r.try_get::<Option<String>, _>("config_json") {
            if let Some(c) = config_str.and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
                out["config"] = c;
            }
        }
        if let Ok(render) = r.try_get::<Option<String>, _>("render") {
            if let Some(ren) = render { out["render"] = json!(ren); }
        }
        if let Ok(ask_params) = r.try_get::<Option<String>, _>("ask_params") {
            if let Some(ap) = ask_params.and_then(|s| split_csv(&s)) {
                out["askParams"] = json!(ap);
            }
        }
        out
    }

    fn enrich_row_metadata(&self, r: &sqlx::sqlite::SqliteRow, val: &mut Value) {
        if let Ok(label) = r.try_get::<String, _>("label") { if !label.is_empty() { val["label"] = json!(label); } }
        if let Ok(provider) = r.try_get::<String, _>("provider") { if !provider.is_empty() { val["provider"] = json!(provider); } }
        if let Ok(category) = r.try_get::<String, _>("category") { if !category.is_empty() { val["category"] = json!(category); } }
        if let Ok(status) = r.try_get::<String, _>("status") { if !status.is_empty() { val["status"] = json!(status); } }
        if let Ok(render) = r.try_get::<Option<String>, _>("render") {
            if let Some(ren) = render { val["render"] = json!(ren); }
        }
        if let Ok(ask_params) = r.try_get::<Option<String>, _>("ask_params") {
            if let Some(ap) = ask_params.and_then(|s| split_csv(&s)) {
                val["askParams"] = json!(ap);
            }
        }
        if let Ok(pricing_str) = r.try_get::<Option<String>, _>("pricing_json") {
            if let Some(p) = pricing_str.and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
                val["pricing"] = p;
            }
        }
    }

    pub async fn get_tool(&self, name: &str) -> Result<Option<Value>, sqlx::Error> {
        let r = sqlx::query("SELECT * FROM tools WHERE name=?")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        Ok(r.map(|row| self.tool_row_to_dict(row)))
    }

    pub async fn remote_endpoint(&self, name: &str) -> Result<Option<String>, sqlx::Error> {
        let r = sqlx::query("SELECT endpoint FROM tools WHERE name=? AND enabled=1")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        Ok(r.and_then(|row| row.get::<Option<String>, _>("endpoint")))
    }

    pub async fn get_tool_config(&self, name: &str) -> Result<Value, sqlx::Error> {
        let r = sqlx::query("SELECT config_json FROM tools WHERE name=?")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        Ok(r.and_then(|row| row.get::<Option<String>, _>("config_json"))
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .unwrap_or(json!({})))
    }

    pub async fn set_tool_config(&self, name: &str, config: &Value) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE tools SET config_json=?,updated_at=? WHERE name=?")
            .bind(config.to_string())
            .bind(now_secs())
            .bind(name)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn update_tool_meta(
        &self, name: &str, label: Option<&str>, blurb: Option<&str>, category: Option<&str>,
        provider: Option<&str>, tier: Option<&str>, amount: Option<&str>, period: Option<&str>
    ) -> Result<(), sqlx::Error> {
        let mut pricing = json!({"tier": tier.unwrap_or("free")});
        let t = tier.unwrap_or("free");
        if (t == "onetime" || t == "subscription") && amount.is_some() {
            if let Some(amt) = amount.and_then(|s| s.parse::<i32>().ok()) {
                pricing["amount"] = json!(amt);
                pricing["currency"] = json!("THB");
                if t == "subscription" {
                    pricing["period"] = json!(period.unwrap_or("month"));
                }
            }
        }

        sqlx::query(
            "UPDATE tools SET label=?,blurb=?,category=?,provider=?,pricing_json=?,updated_at=? WHERE name=?"
        )
        .bind(label)
        .bind(blurb)
        .bind(category)
        .bind(provider)
        .bind(pricing.to_string())
        .bind(now_secs())
        .bind(name)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ---- store (capability) management across all catalog tables -----------------

    pub async fn all_capabilities(&self) -> Result<Vec<Value>, sqlx::Error> {
        let internal_caps = vec!["forget_end_user", "get_transits"];
        let mut out = Vec::new();

        for (tbl, kind) in [("tools", "tool"), ("skills", "skill"), ("mcp_tools", "mcp")] {
            let query_str = format!("SELECT * FROM {}", tbl);
            let rows = sqlx::query(&query_str).fetch_all(&self.pool).await?;
            for r in rows {
                let name: String = r.get("name");
                if internal_caps.contains(&name.as_str()) {
                    continue;
                }
                let enabled = if self.has_column(tbl, "enabled").await? {
                    r.get::<i32, _>("enabled") == 1
                } else {
                    true
                };
                let desc = if self.has_column(tbl, "description").await? {
                    r.get::<Option<String>, _>("description").unwrap_or_default()
                } else {
                    "".to_string()
                };

                let mut extra = json!({});
                self.enrich_row_metadata(&r, &mut extra);

                let mut d = json!({
                    "name": name,
                    "kind": kind,
                    "enabled": enabled,
                    "description": desc,
                });

                if let Some(obj) = extra.as_object() {
                    for (k, v) in obj {
                        d[k] = v.clone();
                    }
                }

                if self.has_column(tbl, "server").await? {
                    d["server"] = json!(r.get::<Option<String>, _>("server"));
                }

                out.push(display::enrich(d));
            }
        }
        Ok(out)
    }

    pub async fn toggle_capability(&self, name: &str) -> Result<bool, sqlx::Error> {
        for tbl in ["tools", "skills", "mcp_tools"] {
            let query = format!("SELECT 1 FROM {} WHERE name=? LIMIT 1", tbl);
            let exists: Option<i32> = sqlx::query_scalar(&query)
                .bind(name)
                .fetch_optional(&self.pool)
                .await?;
            if exists.is_some() {
                let update = format!("UPDATE {} SET enabled=1-enabled WHERE name=?", tbl);
                sqlx::query(&update)
                    .bind(name)
                    .execute(&self.pool)
                    .await?;
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub async fn set_store_meta(
        &self, name: &str, category: Option<&str>, status: Option<&str>,
        tier: Option<&str>, amount: Option<&str>, period: Option<&str>,
        render: Option<&str>, ask_params: Option<&str>
    ) -> Result<(), sqlx::Error> {
        for tbl in ["tools", "skills", "subagents", "mcp_tools"] {
            let exists_query = format!("SELECT 1 FROM {} WHERE name=? LIMIT 1", tbl);
            let exists: Option<i32> = sqlx::query_scalar(&exists_query)
                .bind(name)
                .fetch_optional(&self.pool)
                .await?;
            if exists.is_none() {
                continue;
            }

            let mut sets = Vec::new();
            if category.is_some() { sets.push("category=?"); }
            if status.is_some() { sets.push("status=?"); }
            if render.is_some() && (tbl == "tools" || tbl == "mcp_tools") { sets.push("render=?"); }
            if ask_params.is_some() && (tbl == "tools" || tbl == "mcp_tools") { sets.push("ask_params=?"); }
            if tier.is_some() { sets.push("pricing_json=?"); }

            if !sets.is_empty() {
                self.execute_store_meta_update(tbl, name, category, status, tier, amount, period, render, ask_params).await?;
            }
            break;
        }
        Ok(())
    }

    async fn execute_store_meta_update(
        &self, tbl: &str, name: &str, category: Option<&str>, status: Option<&str>,
        tier: Option<&str>, amount: Option<&str>, period: Option<&str>,
        render: Option<&str>, ask_params: Option<&str>
    ) -> Result<(), sqlx::Error> {
        let mut sets = Vec::new();
        if category.is_some() { sets.push("category=?"); }
        if status.is_some() { sets.push("status=?"); }
        if render.is_some() && (tbl == "tools" || tbl == "mcp_tools") { sets.push("render=?"); }
        if ask_params.is_some() && (tbl == "tools" || tbl == "mcp_tools") { sets.push("ask_params=?"); }
        if tier.is_some() { sets.push("pricing_json=?"); }

        if sets.is_empty() {
            return Ok(());
        }

        let query = format!("UPDATE {} SET {} WHERE name=?", tbl, sets.join(","));
        let mut q = sqlx::query::<sqlx::Sqlite>(&query);
        if let Some(cat) = category { q = q.bind(cat); }
        if let Some(st) = status { q = q.bind(st); }
        if render.is_some() && (tbl == "tools" || tbl == "mcp_tools") {
            q = q.bind(render.and_then(|r| if r.is_empty() { None } else { Some(r) }));
        }
        if ask_params.is_some() && (tbl == "tools" || tbl == "mcp_tools") {
            q = q.bind(ask_params.and_then(|r| if r.is_empty() { None } else { Some(r) }));
        }
        if let Some(t) = tier {
            let mut pricing = json!({"tier": t, "currency": "THB"});
            if (t == "onetime" || t == "subscription") && amount.is_some() {
                if let Some(amt) = amount.and_then(|s| s.parse::<i32>().ok()) {
                    pricing["amount"] = json!(amt);
                }
            }
            if t == "subscription" {
                pricing["period"] = json!(period.unwrap_or("month"));
            }
            q = q.bind(pricing.to_string());
        }
        q.bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn mcp_index(&self) -> Result<HashMap<String, Value>, sqlx::Error> {
        let mut out = HashMap::new();
        let servers_rows = sqlx::query("SELECT * FROM mcp_servers")
            .fetch_all(&self.pool)
            .await?;
        let mut servers = HashMap::new();
        for r in servers_rows {
            let name: String = r.get("name");
            servers.insert(name, r);
        }

        let tools_rows = sqlx::query("SELECT * FROM mcp_tools WHERE enabled=1")
            .fetch_all(&self.pool)
            .await?;
        for t in tools_rows {
            let server_name: String = t.get("server");
            if let Some(s) = servers.get(&server_name) {
                let t_name: String = t.get("name");
                out.insert(t_name.clone(), json!({
                    "server": {
                        "name": s.get::<String, _>("name"),
                        "url": s.get::<String, _>("url"),
                        "headers": serde_json::from_str::<Value>(&s.get::<Option<String>, _>("headers_json").unwrap_or_default()).unwrap_or(json!({}))
                    },
                    "tool": {
                        "name": t_name,
                        "defaults": serde_json::from_str::<Value>(&t.get::<Option<String>, _>("defaults_json").unwrap_or_default()).unwrap_or(json!({}))
                    }
                }));
            }
        }
        Ok(out)
    }

    pub async fn installed_names(&self, table: &str) -> Result<std::collections::HashSet<String>, sqlx::Error> {
        let query = format!("SELECT name FROM {}", table);
        let rows = sqlx::query(&query).fetch_all(&self.pool).await?;
        let mut set = std::collections::HashSet::new();
        for r in rows {
            set.insert(r.get("name"));
        }
        Ok(set)
    }

    pub async fn mcp_tools_for_server(&self, server: &str) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT name,description,label,parameters_json,defaults_json FROM mcp_tools WHERE server=?"
        )
        .bind(server)
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::new();
        for r in rows {
            let name: String = r.get("name");
            let label: String = r.get::<Option<String>, _>("label").unwrap_or(name.clone());
            let description: String = r.get::<Option<String>, _>("description").unwrap_or_default();
            let props = serde_json::from_str::<Value>(&r.get::<Option<String>, _>("parameters_json").unwrap_or_default())
                .ok()
                .and_then(|v| v.get("properties").cloned())
                .unwrap_or(json!({}));
            
            let defaults = serde_json::from_str::<Value>(&r.get::<Option<String>, _>("defaults_json").unwrap_or_default())
                .ok()
                .and_then(|v| v.as_object().cloned())
                .unwrap_or(serde_json::Map::new());

            let mut params = Vec::new();
            if let Some(obj) = props.as_object() {
                for (k, v) in obj {
                    let desc = v.get("description").or_else(|| v.get("title")).and_then(|x| x.as_str()).unwrap_or("");
                    params.push(json!({
                        "key": k,
                        "desc": desc,
                    }));
                }
            }

            let mut seen: std::collections::HashSet<String> = params.iter().map(|p| p["key"].as_str().unwrap_or("").to_string()).collect();
            for k in defaults.keys() {
                if !seen.contains(k) {
                    params.push(json!({
                        "key": k,
                        "desc": "(ฉีดโดย proxy)"
                    }));
                }
            }

            out.push(json!({
                "name": name,
                "label": label,
                "description": description,
                "params": params,
                "defaults": defaults,
            }));
        }
        Ok(out)
    }

    pub async fn set_mcp_defaults(&self, name: &str, defaults: &Value) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE mcp_tools SET defaults_json=? WHERE name=?")
            .bind(defaults.to_string())
            .bind(name)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn get_mcp_server(&self, name: &str) -> Result<Option<Value>, sqlx::Error> {
        let r = sqlx::query("SELECT name,url,headers_json FROM mcp_servers WHERE name=?")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        Ok(r.map(|row| json!({
            "name": row.get::<String, _>("name"),
            "url": row.get::<String, _>("url"),
            "headers": serde_json::from_str::<Value>(&row.get::<Option<String>, _>("headers_json").unwrap_or_default()).unwrap_or(json!({}))
        })))
    }

    pub async fn refresh_mcp_tool(
        &self, server: &str, name: &str, description: &str,
        parameters: &Value, arg_keys: &Value
    ) -> Result<bool, sqlx::Error> {
        let exists: Option<i32> = sqlx::query_scalar("SELECT 1 FROM mcp_tools WHERE name=?")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        if exists.is_some() {
            sqlx::query("UPDATE mcp_tools SET parameters_json=?,arg_keys_json=? WHERE name=?")
                .bind(parameters.to_string())
                .bind(arg_keys.to_string())
                .bind(name)
                .execute(&self.pool)
                .await?;
            Ok(false)
        } else {
            sqlx::query(
                "INSERT INTO mcp_tools(server,name,description,parameters_json,arg_keys_json,enabled,defaults_json) \
                 VALUES(?,?,?,?,?,1,'{}')"
            )
            .bind(server)
            .bind(name)
            .bind(description)
            .bind(parameters.to_string())
            .bind(arg_keys.to_string())
            .execute(&self.pool)
            .await?;
            Ok(true)
        }
    }

    pub async fn uninstall_mcp(&self, name: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM mcp_tools WHERE server=?").bind(name).execute(&self.pool).await?;
        sqlx::query("DELETE FROM mcp_servers WHERE name=?").bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn uninstall_skill(&self, name: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM skills WHERE name=?").bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn uninstall_subagent(&self, name: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM subagents WHERE name=?").bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn install_mcp(&self, srv: &Value) -> Result<(), sqlx::Error> {
        let name = srv["name"].as_str().unwrap_or("");
        let url = srv["url"].as_str().unwrap_or("");
        let headers = srv.get("headers").unwrap_or(&json!({})).to_string();
        let status = if srv.get("audited").and_then(|v| v.as_bool()).unwrap_or(false) { "audited" } else { "review" };
        let category = srv.get("category").and_then(|v| v.as_str()).unwrap_or("");
        let source = src_string(srv);
        let prov = srv.get("provider").and_then(|v| v.as_str()).unwrap_or("");

        sqlx::query(
            "INSERT OR REPLACE INTO mcp_servers(name,url,headers_json,status,category,source) VALUES(?,?,?,?,?,?)"
        )
        .bind(name)
        .bind(url)
        .bind(headers)
        .bind(status)
        .bind(category)
        .bind(&source)
        .execute(&self.pool)
        .await?;

        if let Some(tools) = srv.get("tools").and_then(|v| v.as_array()) {
            for t in tools {
                let t_name = t["name"].as_str().unwrap_or("");
                let t_desc = t.get("description").and_then(|v| v.as_str()).unwrap_or("");
                let t_params = t.get("parameters").unwrap_or(&json!({})).to_string();
                let t_keys = t.get("argKeys").unwrap_or(&json!([])).to_string();
                let t_label = t.get("label").and_then(|v| v.as_str()).unwrap_or("");
                let t_prov = t.get("provider").and_then(|v| v.as_str()).unwrap_or(prov);
                let pricing = pj_string(t).or_else(|| pj_string(srv)).unwrap_or_default();
                let defaults = t.get("defaults").unwrap_or(&json!({})).to_string();

                sqlx::query(
                    "INSERT OR REPLACE INTO mcp_tools(server,name,description,parameters_json,arg_keys_json,enabled,label,category,provider,pricing_json,defaults_json) \
                     VALUES(?,?,?,?,?,1,?,?,?,?,?)"
                )
                .bind(name)
                .bind(t_name)
                .bind(t_desc)
                .bind(t_params)
                .bind(t_keys)
                .bind(t_label)
                .bind(category)
                .bind(t_prov)
                .bind(pricing)
                .bind(defaults)
                .execute(&self.pool)
                .await?;
            }
        }
        Ok(())
    }

    pub async fn install_tool(&self, t: &Value) -> Result<(), sqlx::Error> {
        let name = t["name"].as_str().unwrap_or("");
        let kind = t.get("kind").and_then(|v| v.as_str()).unwrap_or("remote");
        let desc = t.get("description").and_then(|v| v.as_str()).unwrap_or("");
        let params = t.get("parameters").unwrap_or(&json!({"type": "object", "properties": {}})).to_string();
        let keys = t.get("argKeys").unwrap_or(&json!([])).to_string();
        let label = t.get("label").and_then(|v| v.as_str());
        let blurb = t.get("blurb").and_then(|v| v.as_str());
        let cat = t.get("category").and_then(|v| v.as_str());
        let prov = t.get("provider").and_then(|v| v.as_str());
        let pricing = pj_string(t);
        let endpoint = t.get("endpoint").and_then(|v| v.as_str());

        sqlx::query(
            "INSERT OR REPLACE INTO tools(name,kind,description,parameters_json,arg_keys_json,source,enabled,updated_at,label,blurb,category,provider,pricing_json,endpoint) \
             VALUES(?,?,?,?,?,?,1,?,?,?,?,?,?,?)"
        )
        .bind(name)
        .bind(kind)
        .bind(desc)
        .bind(params)
        .bind(keys)
        .bind("dev")
        .bind(now_secs())
        .bind(label)
        .bind(blurb)
        .bind(cat)
        .bind(prov)
        .bind(pricing)
        .bind(endpoint)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn install_skill(&self, s: &Value) -> Result<(), sqlx::Error> {
        let name = s["name"].as_str().unwrap_or("");
        let desc = s.get("description").and_then(|v| v.as_str()).unwrap_or("");
        let inst = s.get("instructions").and_then(|v| v.as_str()).unwrap_or("");
        let reqs = s.get("requires").unwrap_or(&json!({})).to_string();
        let cat = s.get("category").and_then(|v| v.as_str()).unwrap_or("");
        let source = src_string(s);
        let label = s.get("label").and_then(|v| v.as_str());
        let prov = s.get("provider").and_then(|v| v.as_str());
        let pricing = pj_string(s);

        sqlx::query(
            "INSERT OR REPLACE INTO skills(name,description,instructions,requires_json,enabled,category,source,label,provider,pricing_json) \
             VALUES(?,?,?,?,1,?,?,?,?,?)"
        )
        .bind(name)
        .bind(desc)
        .bind(inst)
        .bind(reqs)
        .bind(cat)
        .bind(source)
        .bind(label)
        .bind(prov)
        .bind(pricing)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn install_subagent(&self, s: &Value) -> Result<(), sqlx::Error> {
        let name = s["name"].as_str().unwrap_or("");
        let desc = s.get("description").and_then(|v| v.as_str()).unwrap_or("");
        let system = s.get("system").and_then(|v| v.as_str()).unwrap_or("");
        let tools = s.get("toolNames").unwrap_or(&json!([])).to_string();
        let model = s.get("model").and_then(|v| v.as_str()).unwrap_or("");
        let steps = s.get("maxSteps").and_then(|v| v.as_i64()).unwrap_or(6);
        let cat = s.get("category").and_then(|v| v.as_str()).unwrap_or("");
        let source = src_string(s);
        let label = s.get("label").and_then(|v| v.as_str());
        let prov = s.get("provider").and_then(|v| v.as_str());
        let pricing = pj_string(s);

        sqlx::query(
            "INSERT OR REPLACE INTO subagents(name,description,system,tool_names_json,model,max_steps,category,source,label,provider,pricing_json) \
             VALUES(?,?,?,?,?,?,?,?,?,?,?)"
        )
        .bind(name)
        .bind(desc)
        .bind(system)
        .bind(tools)
        .bind(model)
        .bind(steps)
        .bind(cat)
        .bind(source)
        .bind(label)
        .bind(prov)
        .bind(pricing)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ---- capability requests (backlog) -----------------------------------------

    pub async fn add_capability_request(&self, capability: &str, detail: &str, user: &str) -> Result<(), sqlx::Error> {
        let cap = capability.trim();
        if cap.is_empty() {
            return Ok(());
        }
        let now = now_secs();
        let row = sqlx::query("SELECT id,count,requesters FROM capability_requests WHERE lower(capability)=lower(?)")
            .bind(cap)
            .fetch_optional(&self.pool)
            .await?;

        if let Some(r) = row {
            let req_id: i32 = r.get("id");
            let mut requesters: Vec<String> = serde_json::from_str::<Vec<String>>(&r.get::<Option<String>, _>("requesters").unwrap_or_default())
                .unwrap_or_default();
            if !requesters.contains(&user.to_string()) {
                requesters.push(user.to_string());
                requesters.sort();
            }

            sqlx::query(
                "UPDATE capability_requests SET count=?,requesters=?,updated_at=?,detail=COALESCE(NULLIF(?,''),detail) WHERE id=?"
            )
            .bind(requesters.len() as i32)
            .bind(json!(requesters).to_string())
            .bind(now)
            .bind(detail)
            .bind(req_id)
            .execute(&self.pool)
            .await?;
        } else {
            sqlx::query(
                "INSERT INTO capability_requests(capability,detail,status,count,requesters,created_at,updated_at) \
                 VALUES(?,?, 'requested', 1,?,?,?)"
            )
            .bind(cap)
            .bind(detail)
            .bind(json!([user]).to_string())
            .bind(now)
            .bind(now)
            .execute(&self.pool)
            .await?;
        }
        Ok(())
    }

    pub async fn list_capability_requests(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM capability_requests ORDER BY count DESC, updated_at DESC")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(json!({
                "id": r.get::<i32, _>("id"),
                "capability": r.get::<Option<String>, _>("capability").unwrap_or_default(),
                "detail": r.get::<Option<String>, _>("detail").unwrap_or_default(),
                "status": r.get::<Option<String>, _>("status").unwrap_or_default(),
                "count": r.get::<i32, _>("count"),
                "requesters": serde_json::from_str::<Value>(&r.get::<Option<String>, _>("requesters").unwrap_or_default()).unwrap_or(json!([])),
                "created_at": r.get::<f64, _>("created_at"),
                "updated_at": r.get::<f64, _>("updated_at"),
            }));
        }
        Ok(out)
    }

    pub async fn set_capability_status(&self, req_id: i32, status: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE capability_requests SET status=?,updated_at=? WHERE id=?")
            .bind(status)
            .bind(now_secs())
            .bind(req_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ---- waitlist outreach -----------------------------------------------------

    pub async fn add_waitlist(&self, email: &str, use_case: &str, source: &str) -> Result<(), sqlx::Error> {
        let em = email.trim().to_lowercase();
        if em.is_empty() {
            return Ok(());
        }

        sqlx::query(
            "INSERT INTO waitlist(email,use,source,created_at) VALUES(?,?,?,?) \
             ON CONFLICT(email) DO UPDATE SET use=excluded.use, created_at=excluded.created_at"
        )
        .bind(&em)
        .bind(use_case.trim())
        .bind(source)
        .bind(now_secs())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_waitlist(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM waitlist ORDER BY created_at DESC")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(json!({
                "id": r.get::<i32, _>("id"),
                "email": r.get::<Option<String>, _>("email").unwrap_or_default(),
                "use": r.get::<Option<String>, _>("use").unwrap_or_default(),
                "source": r.get::<Option<String>, _>("source").unwrap_or_default(),
                "created_at": r.get::<Option<f64>, _>("created_at"),
                "sent_at": r.get::<Option<f64>, _>("sent_at"),
                "unsubscribed_at": r.get::<Option<f64>, _>("unsubscribed_at"),
            }));
        }
        Ok(out)
    }

    pub async fn mark_waitlist_sent(&self, email: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE waitlist SET sent_at=? WHERE email=?")
            .bind(now_secs())
            .bind(email)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn mark_waitlist_unsubscribed(&self, email: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE waitlist SET unsubscribed_at=? WHERE email=?")
            .bind(now_secs())
            .bind(email)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ---- mail threads (waitlist outreach + replies) ---------------------------

    pub async fn add_mail_message(
        &self, waitlist_email: &str, direction: &str, subject: &str,
        body: &str, msg_id: &str, in_reply_to: &str
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO mail_messages(waitlist_email,direction,subject,body,msg_id,in_reply_to,created_at) VALUES(?,?,?,?,?,?,?)"
        )
        .bind(waitlist_email)
        .bind(direction)
        .bind(subject)
        .bind(body)
        .bind(msg_id)
        .bind(in_reply_to)
        .bind(now_secs())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn mail_thread(&self, email: &str) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM mail_messages WHERE waitlist_email=? ORDER BY created_at")
            .bind(email)
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(json!({
                "id": r.get::<i32, _>("id"),
                "waitlist_email": r.get::<Option<String>, _>("waitlist_email").unwrap_or_default(),
                "direction": r.get::<Option<String>, _>("direction").unwrap_or_default(),
                "subject": r.get::<Option<String>, _>("subject").unwrap_or_default(),
                "body": r.get::<Option<String>, _>("body").unwrap_or_default(),
                "msg_id": r.get::<Option<String>, _>("msg_id").unwrap_or_default(),
                "in_reply_to": r.get::<Option<String>, _>("in_reply_to").unwrap_or_default(),
                "created_at": r.get::<Option<f64>, _>("created_at"),
            }));
        }
        Ok(out)
    }

    pub async fn mail_reply_counts(&self) -> Result<HashMap<String, i32>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT waitlist_email, COUNT(*) n FROM mail_messages WHERE direction='in' GROUP BY waitlist_email"
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = HashMap::new();
        for r in rows {
            let email: String = r.get("waitlist_email");
            let count: i32 = r.get("n");
            out.insert(email, count);
        }
        Ok(out)
    }

    pub async fn mail_out_index(&self) -> Result<HashMap<String, String>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT msg_id,waitlist_email FROM mail_messages WHERE direction='out' AND msg_id!=''"
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = HashMap::new();
        for r in rows {
            let msg_id: String = r.get("msg_id");
            let email: String = r.get("waitlist_email");
            out.insert(msg_id, email);
        }
        Ok(out)
    }

    pub async fn mail_msgid_seen(&self, msg_id: &str) -> Result<bool, sqlx::Error> {
        if msg_id.is_empty() {
            return Ok(false);
        }
        let exists: Option<i32> = sqlx::query_scalar(
            "SELECT 1 FROM mail_messages WHERE msg_id=? LIMIT 1"
        )
        .bind(msg_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(exists.is_some())
    }

    pub async fn waitlist_email_set(&self) -> Result<std::collections::HashSet<String>, sqlx::Error> {
        let rows = sqlx::query("SELECT email FROM waitlist")
            .fetch_all(&self.pool)
            .await?;
        let mut set = std::collections::HashSet::new();
        for r in rows {
            let email: String = r.get("email");
            set.insert(email);
        }
        Ok(set)
    }

    // ---- push devices ----------------------------------------------------------

    pub async fn record_push_device(&self, user_id: &str, device: &str, platform: &str) -> Result<(), sqlx::Error> {
        if user_id.is_empty() || device.is_empty() {
            return Ok(());
        }

        sqlx::query(
            "INSERT INTO push_devices(user_id,device,platform,updated_at) VALUES(?,?,?,?) \
             ON CONFLICT(user_id) DO UPDATE SET device=excluded.device, platform=excluded.platform, updated_at=excluded.updated_at"
        )
        .bind(user_id)
        .bind(device)
        .bind(platform)
        .bind(now_secs())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_push_devices(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM push_devices ORDER BY updated_at DESC")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(json!({
                "user_id": r.get::<Option<String>, _>("user_id").unwrap_or_default(),
                "device": r.get::<Option<String>, _>("device").unwrap_or_default(),
                "platform": r.get::<Option<String>, _>("platform").unwrap_or_default(),
                "updated_at": r.get::<Option<f64>, _>("updated_at"),
            }));
        }
        Ok(out)
    }

    // ---- tool logs -------------------------------------------------------------

    pub async fn log_tool(&self, tool: &str, kind: &str, arg_keys: &[String], status: &str) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO tool_logs(ts,tool,kind,arg_keys,status) VALUES(?,?,?,?,?)")
            .bind(now_secs())
            .bind(tool)
            .bind(kind)
            .bind(arg_keys.join(","))
            .bind(status)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

// ---- Helpers --------------------------------------------------------------

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn split_csv(s: &str) -> Option<Vec<String>> {
    if s.is_empty() {
        return None;
    }
    let parts: Vec<String> = s.split(',')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.is_empty() {
        None
    } else {
        Some(parts)
    }
}

fn src_string(item: &Value) -> String {
    if let Some(s) = item.get("source") {
        let list = s.get("list").and_then(|v| v.as_str()).unwrap_or("");
        let repo = s.get("repo").and_then(|v| v.as_str()).unwrap_or("");
        let parts: Vec<&str> = vec![list, repo].into_iter().filter(|x| !x.is_empty()).collect();
        parts.join(" · ")
    } else {
        "".to_string()
    }
}

fn pj_string(item: &Value) -> Option<String> {
    item.get("pricing").map(|p| p.to_string())
}
