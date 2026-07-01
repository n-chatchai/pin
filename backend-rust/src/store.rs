use std::collections::HashMap;
use std::time::SystemTime;
use sqlx::{SqlitePool, Row};
use serde_json::{json, Value};
use crate::display;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS assistants(
  name TEXT PRIMARY KEY, label TEXT, description TEXT, version TEXT, status TEXT,
  metadata_json TEXT);
CREATE TABLE IF NOT EXISTS connectors(
  name TEXT PRIMARY KEY, kind TEXT, endpoint TEXT, auth_json TEXT, status TEXT,
  guide TEXT);
CREATE TABLE IF NOT EXISTS capabilities(
  name TEXT PRIMARY KEY, kind TEXT, connector_name TEXT, description TEXT,
  system_prompt TEXT, metadata_json TEXT, enabled INTEGER DEFAULT 1,
  FOREIGN KEY(connector_name) REFERENCES connectors(name) ON DELETE SET NULL);
CREATE TABLE IF NOT EXISTS assistant_capabilities(
  assistant_name TEXT, capability_name TEXT,
  PRIMARY KEY(assistant_name, capability_name),
  FOREIGN KEY(assistant_name) REFERENCES assistants(name) ON DELETE CASCADE,
  FOREIGN KEY(capability_name) REFERENCES capabilities(name) ON DELETE CASCADE);

-- Other system tables
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

        // 2. Run migrations (system tables only)
        let migrations = [
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

        // 3. Seed Assistants and Capabilities
        self.seed_default_assistants().await?;

        // Seed settings
        let _settings_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM system_settings")
            .fetch_one(&self.pool)
            .await?;
        if std::env::var("PIN_FREE_MODEL").is_ok() {
            let free_model = std::env::var("PIN_FREE_MODEL").unwrap_or_else(|_| "gemini-flash-lite-latest".to_string());
            let _ = sqlx::query("INSERT OR IGNORE INTO system_settings (key, value) VALUES (?, ?)")
                .bind("pin_free_model").bind(free_model)
                .execute(&self.pool).await;
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

    pub async fn is_admin(&self, ident: &str) -> Result<bool, sqlx::Error> {
        // Accept a Matrix user_id (@local:domain), an email (local@domain), or a
        // bare localpart. Owners in admin_users may be stored full or bare.
        let ident = ident.trim();
        let local = ident.trim_start_matches('@')
            .split([':', '@']).next().unwrap_or(ident);
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM admin_users WHERE email = ? OR email = ?")
            .bind(ident)
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

    async fn seed_default_assistants(&self) -> Result<(), sqlx::Error> {
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM assistants")
            .fetch_one(&self.pool)
            .await?;
        if count > 0 {
            return Ok(());
        }

        let display_map = display::get_display();

        // 1. Seed Assistants (ผู้ช่วย = delegate/handoff agents; config in metadata_json)
        // Assistants mirror the site use-cases (site/index.html): งาน/เรียน/บ้าน/ครีเอทีฟ/ร้าน.
        // description = user-facing blurb (friendly); system = the agent's prompt (technical).
        // status 'soon' = shown as "เร็วๆนี้" in the app (waitlist framing).
        let assistants = vec![
            ("study", "ติวและทบทวน", "อธิบายทีละขั้น สรุปโน้ต เตือนส่งงาน", "active",
             json!({"model": "gemini-2.5-pro", "interaction_mode": "handoff", "category": "เรียน", "toolNames": ["web_search", "recall_knowledge", "add_watch"], "system": "คุณเป็นติวเตอร์ใจดี อดทน. อธิบายทีละขั้น ยกตัวอย่างใกล้ตัว เช็กความเข้าใจเป็นระยะ. อย่าเฉลยตรงๆ ให้ผู้เรียนคิดก่อน."})),
            ("home", "ดูแลบ้าน", "เตือนกินยา จดของซื้อ เช็กอากาศ", "active",
             json!({"model": "haiku", "interaction_mode": "delegation", "maxSteps": 6, "category": "บ้าน", "toolNames": ["get_weather", "add_watch", "remember_fact"], "system": "ช่วยดูแลเรื่องในบ้าน: เตือนกินยา/นัดหมาย, จดของที่ต้องซื้อ, เช็กอากาศ. กระชับ ใช้ได้จริง."})),
            ("creative", "งานครีเอทีฟ", "ร่างแคปชัน วาดรูป คิดไอเดีย", "active",
             json!({"model": "haiku", "interaction_mode": "delegation", "maxSteps": 6, "category": "ครีเอทีฟ", "toolNames": ["generate_image", "web_search"], "system": "ช่วยงานครีเอทีฟ: ร่างแคปชัน/คอนเทนต์, วาดรูปประกอบ, ระดมไอเดีย. เสนอหลายทางเลือก."})),
            ("work", "จัดการงาน", "สรุปอีเมล นัดประชุม ทวงงานให้", "soon",
             json!({"interaction_mode": "delegation", "category": "งาน"})),
            ("shop", "ดูแลร้านค้า", "สรุปยอด เช็กค่าเงิน ตอบแชตลูกค้า", "soon",
             json!({"interaction_mode": "delegation", "category": "ร้านค้า"})),
        ];
        for (name, label, desc, status, meta) in assistants {
            sqlx::query("INSERT INTO assistants(name, label, description, status, metadata_json) VALUES(?, ?, ?, ?, ?)")
                .bind(name).bind(label).bind(desc).bind(status).bind(meta.to_string()).execute(&self.pool).await?;
        }

        // 2. Seed Connectors (with usage guide — policy for driving its tools)
        let lakkana_guide = "เมื่อผู้ใช้อยากดูดวง ใช้เครื่องมือดูดวงของอาจารย์ลักขณาที่มีในระบบ.\n- เก็บวันเกิด/เวลาเกิด(ไม่รู้ใช้ 12:00)/เมืองเกิด ให้ครบก่อนเรียก บอกว่าใช้คำนวณเท่านั้น\n- ถ้าเครื่องมือให้เลือกระบบหรือหัวข้อ ถามผู้ใช้ก่อน อย่าเดาเอง\n- ห้ามแต่งคำทำนายหรือตำแหน่งดาวเอง ใช้ผลจากเครื่องมือเท่านั้น\n- นำเสนออบอุ่น ให้กำลังใจ เตือนว่าเป็นความเชื่อส่วนบุคคล";
        sqlx::query("INSERT INTO connectors(name, kind, endpoint, status, guide) VALUES ('lakkana', 'mcp', 'http://localhost:3000', 'active', ?)")
            .bind(lakkana_guide).execute(&self.pool).await?;

        // 3. Seed Capabilities (Tools)
        let tools = vec![
            ("get_weather", "tool", "ดูพยากรณ์อากาศของเมืองที่ระบุ", json!({"parameters": {"type": "object", "properties": {"place": {"type": "string"}, "days": {"type": "integer"}}}})),
            ("get_currency", "tool", "ดูอัตราแลกเปลี่ยน เช่น USD/THB", json!({"parameters": {"type": "object", "properties": {"base": {"type": "string"}, "quote": {"type": "string"}}}})),
            ("web_search", "tool", "ค้นข้อมูลสด/ปัจจุบันจากเว็บ (ข่าว/ผลบอล/ราคา)", json!({"parameters": {"type": "object", "properties": {"query": {"type": "string"}}}})),
            ("news", "tool", "ผู้สื่อข่าว", json!({})),
            ("generate_image", "tool", "วาดรูป", json!({})),
        ];
        
        for (name, kind, desc, meta) in tools {
            let mut metadata = meta;
            if let Some(d) = display_map.get(name) {
                metadata["display"] = d.clone();
            }
            sqlx::query("INSERT INTO capabilities(name, kind, description, metadata_json, enabled) VALUES(?, ?, ?, ?, 1)")
                .bind(name).bind(kind).bind(desc).bind(metadata.to_string()).execute(&self.pool).await?;
        }

        // 4. Seed Capabilities (Skills)
        let skills = vec![
            ("email_triage", "skill", "คัดกรองอีเมล", json!({})),
            ("fortune", "skill", "ดูดวง", json!({})),
            ("joke", "skill", "เล่าเรื่องตลก", json!({})),
            ("line_assistant", "skill", "ผู้ช่วยผ่าน LINE", json!({})),
            ("watch", "skill", "นาฬิกา", json!({})),
        ];

        for (name, kind, desc, meta) in skills {
            sqlx::query("INSERT INTO capabilities(name, kind, description, metadata_json, enabled) VALUES(?, ?, ?, ?, 1)")
                .bind(name).bind(kind).bind(desc).bind(meta.to_string()).execute(&self.pool).await?;
        }

        // 5. Bind assistants -> the tool capabilities they use (M:M).
        // Only existing capabilities bind here; on-device tools (add_watch,
        // recall_knowledge, remember_fact) live in metadata.toolNames.
        let mappings = vec![
            ("study", "web_search"),
            ("home", "get_weather"),
            ("creative", "generate_image"),
            ("creative", "web_search"),
        ];
        for (ast, cap) in mappings {
            sqlx::query("INSERT INTO assistant_capabilities(assistant_name, capability_name) VALUES(?, ?)")
                .bind(ast).bind(cap).execute(&self.pool).await?;
        }

        Ok(())
    }

    // ---- reads used by the catalog / MCP layers --------------------------------

    pub async fn enabled_hosted_tools(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM capabilities WHERE enabled=1 AND kind='tool'")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(self.capability_to_dict(&r));
        }
        Ok(out)
    }

    pub async fn enabled_mcp_tools(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM capabilities WHERE enabled=1 AND kind='mcp'")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(self.capability_to_dict(&r));
        }
        Ok(out)
    }

    pub async fn enabled_skills(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM capabilities WHERE enabled=1 AND kind='skill'")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(self.capability_to_dict(&r));
        }
        Ok(out)
    }

    pub async fn enabled_subagents(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM capabilities WHERE enabled=1 AND kind='subagent'")
            .fetch_all(&self.pool)
            .await?;
        let mut out = Vec::new();
        for r in rows {
            out.push(self.capability_to_dict(&r));
        }
        Ok(out)
    }

    pub async fn enabled_assistants(&self) -> Result<Vec<Value>, sqlx::Error> {
        // include 'soon' so the app can show coming-soon use-cases (waitlist framing)
        let rows = sqlx::query("SELECT * FROM assistants WHERE status IN ('active','soon')")
            .fetch_all(&self.pool)
            .await?;
            
        let mut out = Vec::new();
        for r in rows {
            let name: String = r.get("name");
            
            // fetch capabilities for this assistant
            let caps_rows = sqlx::query("SELECT capability_name FROM assistant_capabilities WHERE assistant_name=?")
                .bind(&name)
                .fetch_all(&self.pool)
                .await?;
                
            let mut capabilities = Vec::new();
            for cr in caps_rows {
                let c_name: String = cr.get("capability_name");
                capabilities.push(c_name);
            }

            // Merge the assistant's agent config (model/system/toolNames/interaction_mode).
            // Tolerant of an older schema without the metadata_json column.
            let meta_str = r.try_get::<Option<String>, _>("metadata_json").ok().flatten()
                .unwrap_or_else(|| "{}".to_string());
            let mut d: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
            d["name"] = json!(name);
            d["label"] = json!(r.get::<Option<String>, _>("label").unwrap_or_default());
            d["description"] = json!(r.get::<Option<String>, _>("description").unwrap_or_default());
            d["status"] = json!(r.get::<String, _>("status"));
            d["capabilities"] = json!(capabilities);
            out.push(d);
        }
        Ok(out)
    }

    pub fn capability_to_dict(&self, r: &sqlx::sqlite::SqliteRow) -> Value {
        let meta_str = r.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
        let mut meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
        
        meta["name"] = json!(r.get::<String, _>("name"));
        meta["kind"] = json!(r.get::<String, _>("kind"));
        meta["description"] = json!(r.get::<Option<String>, _>("description").unwrap_or_default());
        
        if let Ok(connector) = r.try_get::<Option<String>, _>("connector_name") {
            if let Some(c) = connector { meta["server"] = json!(c); }
        }
        
        // Ensure defaults are present for legacy client expectation
        if meta.get("parameters").is_none() { meta["parameters"] = json!({}); }
        if meta.get("argKeys").is_none() { meta["argKeys"] = json!([]); }
        
        meta
    }

    pub async fn get_tool(&self, name: &str) -> Result<Option<Value>, sqlx::Error> {
        let r = sqlx::query("SELECT * FROM capabilities WHERE name=?")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        Ok(r.map(|row| self.capability_to_dict(&row)))
    }

    pub async fn remote_endpoint(&self, name: &str) -> Result<Option<String>, sqlx::Error> {
        // Find if this capability uses a connector
        let r = sqlx::query(
            "SELECT c.endpoint FROM capabilities cap LEFT JOIN connectors c ON cap.connector_name = c.name WHERE cap.name=? AND cap.enabled=1"
        )
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(r.and_then(|row| row.get::<Option<String>, _>("endpoint")))
    }

    pub async fn get_tool_config(&self, name: &str) -> Result<Value, sqlx::Error> {
        let r = sqlx::query("SELECT metadata_json FROM capabilities WHERE name=?")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        
        let meta_str = r.and_then(|row| row.get::<Option<String>, _>("metadata_json")).unwrap_or_else(|| "{}".to_string());
        let meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
        Ok(meta.get("config").cloned().unwrap_or(json!({})))
    }

    pub async fn set_tool_config(&self, name: &str, config: &Value) -> Result<(), sqlx::Error> {
        // Read existing meta
        let r = sqlx::query("SELECT metadata_json FROM capabilities WHERE name=?").bind(name).fetch_optional(&self.pool).await?;
        if let Some(row) = r {
            let meta_str = row.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
            let mut meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
            meta["config"] = config.clone();
            
            sqlx::query("UPDATE capabilities SET metadata_json=? WHERE name=?")
                .bind(meta.to_string())
                .bind(name)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    pub async fn update_tool_meta(
        &self, name: &str, label: Option<&str>, blurb: Option<&str>, category: Option<&str>,
        provider: Option<&str>, tier: Option<&str>, amount: Option<&str>, period: Option<&str>
    ) -> Result<(), sqlx::Error> {
        let r = sqlx::query("SELECT metadata_json FROM capabilities WHERE name=?").bind(name).fetch_optional(&self.pool).await?;
        if let Some(row) = r {
            let meta_str = row.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
            let mut meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
            
            if let Some(l) = label { meta["label"] = json!(l); }
            if let Some(b) = blurb { meta["blurb"] = json!(b); }
            if let Some(c) = category { meta["category"] = json!(c); }
            if let Some(p) = provider { meta["provider"] = json!(p); }
            
            let t = tier.unwrap_or("free");
            let mut pricing = json!({"tier": t});
            if (t == "onetime" || t == "subscription") && amount.is_some() {
                if let Some(amt) = amount.and_then(|s| s.parse::<i32>().ok()) {
                    pricing["amount"] = json!(amt);
                    pricing["currency"] = json!("THB");
                    if t == "subscription" {
                        pricing["period"] = json!(period.unwrap_or("month"));
                    }
                }
            }
            meta["pricing"] = pricing;

            sqlx::query("UPDATE capabilities SET metadata_json=? WHERE name=?")
                .bind(meta.to_string())
                .bind(name)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    // ---- store (capability) management across all catalog tables -----------------

    pub async fn all_capabilities(&self) -> Result<Vec<Value>, sqlx::Error> {
        let internal_caps = vec!["forget_end_user", "get_transits"];
        let rows = sqlx::query("SELECT * FROM capabilities").fetch_all(&self.pool).await?;
        let mut out = Vec::new();

        for r in rows {
            let name: String = r.get("name");
            if internal_caps.contains(&name.as_str()) { continue; }
            out.push(display::enrich(self.capability_to_dict(&r)));
        }
        Ok(out)
    }

    /// Admin view: every capability (no internal-tool filter), with its enabled flag.
    pub async fn all_capabilities_admin(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM capabilities ORDER BY kind, name").fetch_all(&self.pool).await?;
        let mut out = Vec::new();
        for r in rows {
            let mut d = self.capability_to_dict(&r);
            d["enabled"] = json!(r.get::<i64, _>("enabled") != 0);
            d["system_prompt"] = json!(r.get::<Option<String>, _>("system_prompt").unwrap_or_default());
            out.push(d);
        }
        Ok(out)
    }

    /// Admin view: every connector with its MCP tool names.
    pub async fn all_connectors(&self) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query("SELECT * FROM connectors ORDER BY name").fetch_all(&self.pool).await?;
        let mut out = Vec::new();
        for r in rows {
            let name: String = r.get("name");
            let tools = self.mcp_tools_for_server(&name).await.unwrap_or_default();
            let guide = r.try_get::<Option<String>, _>("guide").ok().flatten().unwrap_or_default();
            out.push(json!({
                "name": name,
                "kind": r.get::<Option<String>, _>("kind").unwrap_or_default(),
                "endpoint": r.get::<Option<String>, _>("endpoint").unwrap_or_default(),
                "status": r.get::<Option<String>, _>("status").unwrap_or_default(),
                "guide": guide,
                "tools": tools,
            }));
        }
        Ok(out)
    }

    /// Edit a skill/subagent's prompt (system_prompt column).
    pub async fn set_prompt(&self, name: &str, prompt: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE capabilities SET system_prompt=? WHERE name=?")
            .bind(prompt).bind(name).execute(&self.pool).await?;
        Ok(())
    }

    /// Edit a connector's usage guide (how the agent should drive its tools).
    /// Untouched by MCP refresh — it's admin-owned policy, not live schema.
    pub async fn set_connector_guide(&self, name: &str, guide: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE connectors SET guide=? WHERE name=?")
            .bind(guide).bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn toggle_capability(&self, name: &str) -> Result<bool, sqlx::Error> {
        let exists: Option<i32> = sqlx::query_scalar("SELECT 1 FROM capabilities WHERE name=? LIMIT 1")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        if exists.is_some() {
            sqlx::query("UPDATE capabilities SET enabled=1-enabled WHERE name=?")
                .bind(name)
                .execute(&self.pool)
                .await?;
            return Ok(true);
        }
        Ok(false)
    }

    pub async fn set_store_meta(
        &self, name: &str, category: Option<&str>, status: Option<&str>,
        tier: Option<&str>, amount: Option<&str>, period: Option<&str>,
        render: Option<&str>, ask_params: Option<&str>
    ) -> Result<(), sqlx::Error> {
        let r = sqlx::query("SELECT metadata_json FROM capabilities WHERE name=?").bind(name).fetch_optional(&self.pool).await?;
        if let Some(row) = r {
            let meta_str = row.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
            let mut meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
            
            if let Some(c) = category { meta["category"] = json!(c); }
            if let Some(s) = status { meta["status"] = json!(s); }
            if let Some(ren) = render { meta["render"] = json!(ren); }
            
            if let Some(ap) = ask_params {
                if let Some(ap_list) = split_csv(ap) {
                    meta["askParams"] = json!(ap_list);
                }
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
                meta["pricing"] = pricing;
            }

            sqlx::query("UPDATE capabilities SET metadata_json=? WHERE name=?")
                .bind(meta.to_string())
                .bind(name)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    pub async fn mcp_index(&self) -> Result<HashMap<String, Value>, sqlx::Error> {
        let mut out = HashMap::new();
        let servers_rows = sqlx::query("SELECT * FROM connectors WHERE kind='mcp'")
            .fetch_all(&self.pool)
            .await?;
        let mut servers = HashMap::new();
        for r in servers_rows {
            let name: String = r.get("name");
            servers.insert(name, r);
        }

        let tools_rows = sqlx::query("SELECT * FROM capabilities WHERE enabled=1 AND kind='mcp'")
            .fetch_all(&self.pool)
            .await?;
        for t in tools_rows {
            let server_name = t.get::<Option<String>, _>("connector_name").unwrap_or_default();
            if let Some(s) = servers.get(&server_name) {
                let t_name: String = t.get("name");
                let meta_str = t.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
                let meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
                
                let s_auth_str = s.get::<Option<String>, _>("auth_json").unwrap_or_else(|| "{}".to_string());
                let s_auth: Value = serde_json::from_str(&s_auth_str).unwrap_or(json!({}));
                
                out.insert(t_name.clone(), json!({
                    "server": {
                        "name": s.get::<String, _>("name"),
                        "url": s.get::<String, _>("endpoint"),
                        "headers": s_auth.get("headers").cloned().unwrap_or(json!({}))
                    },
                    "tool": {
                        "name": t_name,
                        "defaults": meta.get("defaults").cloned().unwrap_or(json!({}))
                    }
                }));
            }
        }
        Ok(out)
    }

    pub async fn installed_names(&self, _table: &str) -> Result<std::collections::HashSet<String>, sqlx::Error> {
        // Fallback for old callers that specify 'tools', 'skills', etc. We just pull all capability names.
        let query = "SELECT name FROM capabilities";
        let rows = sqlx::query(query).fetch_all(&self.pool).await?;
        let mut set = std::collections::HashSet::new();
        for r in rows {
            set.insert(r.get("name"));
        }
        Ok(set)
    }

    pub async fn mcp_tools_for_server(&self, server: &str) -> Result<Vec<Value>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT name,description,metadata_json FROM capabilities WHERE connector_name=? AND kind='mcp'"
        )
        .bind(server)
        .fetch_all(&self.pool)
        .await?;
        
        let mut out = Vec::new();
        for r in rows {
            let name: String = r.get("name");
            let description: String = r.get::<Option<String>, _>("description").unwrap_or_default();
            
            let meta_str = r.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
            let meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
            
            let label = meta.get("label").and_then(|v| v.as_str()).unwrap_or(&name).to_string();
            
            let props = meta.get("parameters")
                .and_then(|v| v.get("properties"))
                .cloned()
                .unwrap_or(json!({}));
            
            let defaults = meta.get("defaults")
                .and_then(|v| v.as_object())
                .cloned()
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

            let seen: std::collections::HashSet<String> = params.iter().map(|p| p["key"].as_str().unwrap_or("").to_string()).collect();
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
        let r = sqlx::query("SELECT metadata_json FROM capabilities WHERE name=?").bind(name).fetch_optional(&self.pool).await?;
        if let Some(row) = r {
            let meta_str = row.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
            let mut meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
            meta["defaults"] = defaults.clone();
            
            sqlx::query("UPDATE capabilities SET metadata_json=? WHERE name=?")
                .bind(meta.to_string())
                .bind(name)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    pub async fn get_mcp_server(&self, name: &str) -> Result<Option<Value>, sqlx::Error> {
        let r = sqlx::query("SELECT name,endpoint,auth_json FROM connectors WHERE name=? AND kind='mcp'")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
        Ok(r.map(|row| {
            let auth_str = row.get::<Option<String>, _>("auth_json").unwrap_or_else(|| "{}".to_string());
            let auth: Value = serde_json::from_str(&auth_str).unwrap_or(json!({}));
            json!({
                "name": row.get::<String, _>("name"),
                "url": row.get::<String, _>("endpoint"),
                "headers": auth.get("headers").cloned().unwrap_or(json!({}))
            })
        }))
    }

    pub async fn refresh_mcp_tool(
        &self, server: &str, name: &str, description: &str,
        parameters: &Value, arg_keys: &Value
    ) -> Result<bool, sqlx::Error> {
        let exists: Option<i32> = sqlx::query_scalar("SELECT 1 FROM capabilities WHERE name=? AND kind='mcp'")
            .bind(name)
            .fetch_optional(&self.pool)
            .await?;
            
        let mut meta = json!({
            "parameters": parameters.clone(),
            "argKeys": arg_keys.clone()
        });
            
        if exists.is_some() {
            // Need to merge with existing meta
            let r = sqlx::query("SELECT metadata_json FROM capabilities WHERE name=?").bind(name).fetch_optional(&self.pool).await?;
            if let Some(row) = r {
                let meta_str = row.get::<Option<String>, _>("metadata_json").unwrap_or_else(|| "{}".to_string());
                let mut existing_meta: Value = serde_json::from_str(&meta_str).unwrap_or(json!({}));
                existing_meta["parameters"] = parameters.clone();
                existing_meta["argKeys"] = arg_keys.clone();
                meta = existing_meta;
            }
            
            sqlx::query("UPDATE capabilities SET metadata_json=? WHERE name=?")
                .bind(meta.to_string())
                .bind(name)
                .execute(&self.pool)
                .await?;
            Ok(false)
        } else {
            sqlx::query(
                "INSERT INTO capabilities(name, kind, connector_name, description, metadata_json, enabled) VALUES(?, 'mcp', ?, ?, ?, 1)"
            )
            .bind(name)
            .bind(server)
            .bind(description)
            .bind(meta.to_string())
            .execute(&self.pool)
            .await?;
            Ok(true)
        }
    }

    pub async fn uninstall_mcp(&self, name: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM capabilities WHERE connector_name=? AND kind='mcp'").bind(name).execute(&self.pool).await?;
        sqlx::query("DELETE FROM connectors WHERE name=?").bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn uninstall_skill(&self, name: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM capabilities WHERE name=? AND kind='skill'").bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn uninstall_subagent(&self, name: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM capabilities WHERE name=? AND kind='subagent'").bind(name).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn install_mcp(&self, srv: &Value) -> Result<(), sqlx::Error> {
        let name = srv["name"].as_str().unwrap_or("");
        let url = srv["url"].as_str().unwrap_or("");
        let headers = srv.get("headers").cloned().unwrap_or(json!({}));
        let status = if srv.get("audited").and_then(|v| v.as_bool()).unwrap_or(false) { "audited" } else { "review" };
        
        let auth_json = json!({"headers": headers});

        sqlx::query(
            "INSERT OR REPLACE INTO connectors(name,kind,endpoint,auth_json,status) VALUES(?,'mcp',?,?,?)"
        )
        .bind(name)
        .bind(url)
        .bind(auth_json.to_string())
        .bind(status)
        .execute(&self.pool)
        .await?;

        if let Some(tools) = srv.get("tools").and_then(|v| v.as_array()) {
            for t in tools {
                let t_name = t["name"].as_str().unwrap_or("");
                let t_desc = t.get("description").and_then(|v| v.as_str()).unwrap_or("");
                
                let mut meta = t.clone();
                meta["provider"] = srv.get("provider").cloned().unwrap_or(json!(""));
                
                sqlx::query(
                    "INSERT OR REPLACE INTO capabilities(name,kind,connector_name,description,metadata_json,enabled) VALUES(?,'mcp',?,?,?,1)"
                )
                .bind(t_name)
                .bind(name)
                .bind(t_desc)
                .bind(meta.to_string())
                .execute(&self.pool)
                .await?;
            }
        }
        Ok(())
    }

    pub async fn install_tool(&self, t: &Value) -> Result<(), sqlx::Error> {
        let name = t["name"].as_str().unwrap_or("");
        let desc = t.get("description").and_then(|v| v.as_str()).unwrap_or("");
        
        sqlx::query(
            "INSERT OR REPLACE INTO capabilities(name,kind,description,metadata_json,enabled) VALUES(?,'tool',?,?,1)"
        )
        .bind(name)
        .bind(desc)
        .bind(t.to_string())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn install_skill(&self, s: &Value) -> Result<(), sqlx::Error> {
        let name = s["name"].as_str().unwrap_or("");
        let desc = s.get("description").and_then(|v| v.as_str()).unwrap_or("");
        
        sqlx::query(
            "INSERT OR REPLACE INTO capabilities(name,kind,description,metadata_json,enabled) VALUES(?,'skill',?,?,1)"
        )
        .bind(name)
        .bind(desc)
        .bind(s.to_string())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn install_subagent(&self, s: &Value) -> Result<(), sqlx::Error> {
        let name = s["name"].as_str().unwrap_or("");
        let desc = s.get("description").and_then(|v| v.as_str()).unwrap_or("");
        
        sqlx::query(
            "INSERT OR REPLACE INTO capabilities(name,kind,description,metadata_json,enabled) VALUES(?,'subagent',?,?,1)"
        )
        .bind(name)
        .bind(desc)
        .bind(s.to_string())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn install_assistant(&self, ast: &Value) -> Result<(), sqlx::Error> {
        let name = ast["name"].as_str().unwrap_or("");
        let label = ast.get("label").and_then(|v| v.as_str()).unwrap_or("");
        let desc = ast.get("description").and_then(|v| v.as_str()).unwrap_or("");
        
        sqlx::query(
            "INSERT OR REPLACE INTO assistants(name,label,description,status) VALUES(?,?,?,'active')"
        )
        .bind(name)
        .bind(label)
        .bind(desc)
        .execute(&self.pool)
        .await?;
        
        if let Some(caps) = ast.get("capabilities").and_then(|v| v.as_array()) {
            for cap in caps {
                if let Some(cap_name) = cap.as_str() {
                    sqlx::query("INSERT OR IGNORE INTO assistant_capabilities(assistant_name, capability_name) VALUES(?,?)")
                        .bind(name)
                        .bind(cap_name)
                        .execute(&self.pool)
                        .await?;
                }
            }
        }
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

