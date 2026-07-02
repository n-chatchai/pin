use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::OnceLock;

static DISPLAY: OnceLock<HashMap<&'static str, Value>> = OnceLock::new();

pub fn get_display() -> &'static HashMap<&'static str, Value> {
    DISPLAY.get_or_init(|| {
        let mut m = HashMap::new();
        m.insert("get_weather", json!({
            "category": "ข้อมูล", "label": "พยากรณ์อากาศ",
            "blurb": "บอกอากาศแต่ละเมือง", "icon": "cloud",
            "group": "ready", "provider": "Open-Meteo",
            "pricing": {"tier": "free"}
        }));
        m.insert("get_currency", json!({
            "category": "ข้อมูล", "label": "อัตราแลกเปลี่ยน",
            "blurb": "แปลงสกุลเงินให้", "icon": "coins",
            "group": "ready", "provider": "Frankfurter",
            "pricing": {"tier": "free"}
        }));
        m.insert("web_search", json!({
            "category": "ข้อมูล", "label": "ค้นข้อมูลในเว็บ",
            "blurb": "หาข้อมูลสดจากเน็ต", "icon": "search",
            "group": "ready", "provider": "ปิ่น",
            "pricing": {"tier": "free"}
        }));
        m.insert("news", json!({
            "category": "ข่าวสาร", "label": "สรุปข่าว",
            "blurb": "สรุปข่าวที่คุณสนใจ", "icon": "newspaper",
            "group": "ready", "provider": "ปิ่น",
            "pricing": {"tier": "free"}
        }));
        m.insert("generate_image", json!({
            "category": "สร้างสรรค์", "label": "สร้างรูปภาพ",
            "blurb": "วาดหรือสร้างรูปจากคำบอก", "icon": "image",
            "group": "ready", "provider": "ปิ่น",
            "pricing": {"tier": "free"}
        }));
        m.insert("joke", json!({
            "category": "บันเทิง", "label": "เล่ามุก",
            "blurb": "ขอมุกตลกคลายเครียด", "icon": "smiley",
            "group": "ready", "provider": "ปิ่น",
            "pricing": {"tier": "free"}
        }));
        m.insert("fortune", json!({
            "category": "ดูดวง", "label": "ดูดวงเบื้องต้น",
            "blurb": "เสี่ยงทาย ทำนายเล่น ๆ", "icon": "star",
            "group": "ready", "provider": "ปิ่น",
            "pricing": {"tier": "free"}
        }));
        m.insert("watch", json!({
            "category": "ผู้ช่วย", "label": "เฝ้าติดตามให้",
            "blurb": "คอยจับตาเรื่องที่คุณสนใจ แล้วเตือน", "icon": "eye",
            "group": "ready", "provider": "ปิ่น",
            "pricing": {"tier": "free"}
        }));
        m.insert("get_reading", json!({
            "category": "ไลฟ์สไตล์", "label": "ดูดวงลัคนา",
            "blurb": "ผูกดวงไทย+สากลจากวันเกิด อ่านดวงเฉพาะคุณ",
            "icon": "star", "group": "ready", "status": "trial",
            "provider": "ลักษณา"
        }));
        m.insert("line_assistant", json!({
            "category": "เชื่อมบัญชี", "label": "ผู้ช่วยผ่าน LINE",
            "blurb": "คุยกับปิ่นผ่าน LINE · เตือนเข้า LINE", "icon": "chat",
            "group": "connect", "needs_connect": true, "status": "soon",
            "provider": "LINE", "pricing": {"tier": "subscription", "amount": 39, "currency": "THB", "period": "month"}
        }));
        m.insert("email_triage", json!({
            "category": "เชื่อมบัญชี", "label": "คัดกรองอีเมล",
            "blurb": "สรุปเมลด่วน ร่างตอบ", "icon": "mail",
            "group": "connect", "needs_connect": true, "status": "soon",
            "provider": "Google", "pricing": {"tier": "subscription", "amount": 59, "currency": "THB", "period": "month"}
        }));
        m
    })
}

pub fn enrich(mut entry: Value) -> Value {
    let name = entry.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let display_map = get_display();
    if let Some(base) = display_map.get(name) {
        if let Some(base_obj) = base.as_object() {
            if let Some(entry_obj) = entry.as_object_mut() {
                for (k, v) in base_obj {
                    if !entry_obj.contains_key(k)
                        || entry_obj.get(k).is_none_or(|val| val.is_null())
                    {
                        entry_obj.insert(k.clone(), v.clone());
                    }
                }
            }
        }
    }
    entry
}
