"""Consumer-facing display + commerce metadata for catalog entries — the layer
the app renders, so users never see "tool/skill/mcp/subagent". Keyed by entry
name. Fields:

  label, blurb, icon, category, group  — presentation
  provider                             — who supplies it (Google / Notion / ปิ่น)
  pricing = {tier, amount, currency, period}
       tier: "free" | "onetime" | "subscription"

Entries without a mapping are hidden from the app's "ความสามารถ" screen.
"""

from __future__ import annotations


def _free():
    return {"tier": "free"}


def _sub(amount, period="month"):
    return {"tier": "subscription", "amount": amount, "currency": "THB",
            "period": period}


DISPLAY = {
    # hosted tools — free, provided by upstream data sources
    "get_weather": {"category": "ข้อมูล", "label": "พยากรณ์อากาศ",
                    "blurb": "บอกอากาศแต่ละเมือง", "icon": "cloud",
                    "group": "ready", "provider": "Open-Meteo", "pricing": _free()},
    "get_currency": {"category": "ข้อมูล", "label": "อัตราแลกเปลี่ยน",
                     "blurb": "แปลงสกุลเงินให้", "icon": "coins",
                     "group": "ready", "provider": "Frankfurter", "pricing": _free()},
    "web_search": {"category": "ข้อมูล", "label": "ค้นข้อมูลในเว็บ",
                   "blurb": "หาข้อมูลสดจากเน็ต", "icon": "search",
                   "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    "news": {"category": "ข่าวสาร", "label": "สรุปข่าว",
             "blurb": "สรุปข่าวที่คุณสนใจ", "icon": "newspaper",
             "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    # skills — free, by ปิ่น
    "generate_image": {"category": "สร้างสรรค์", "label": "สร้างรูปภาพ",
                       "blurb": "วาดหรือสร้างรูปจากคำบอก", "icon": "image",
                       "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    "joke": {"category": "บันเทิง", "label": "เล่ามุก",
             "blurb": "ขอมุกตลกคลายเครียด", "icon": "smiley",
             "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    "fortune": {"category": "ดูดวง", "label": "ดูดวงเบื้องต้น",
                "blurb": "เสี่ยงทาย ทำนายเล่น ๆ", "icon": "star",
                "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    "watch": {"category": "ผู้ช่วย", "label": "เฝ้าติดตามให้",
              "blurb": "คอยจับตาเรื่องที่คุณสนใจ แล้วเตือน", "icon": "eye",
              "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    # ดูดวง — lakkana.app MCP, tool get_reading (get_transits is a no-charge
    # data helper, hidden from the store via store._INTERNAL_CAPS).
    "get_reading": {"category": "ไลฟ์สไตล์", "label": "ดูดวงลัคนา",
                           "blurb": "ผูกดวงไทย+สากลจากวันเกิด อ่านดวงเฉพาะคุณ",
                           "icon": "star", "group": "ready", "status": "trial",
                           "provider": "ลักษณา"},
    # account connects — coming soon (Gmail/LINE not wired yet).
    "line_assistant": {"category": "เชื่อมบัญชี", "label": "ผู้ช่วยผ่าน LINE",
                       "blurb": "คุยกับปิ่นผ่าน LINE · เตือนเข้า LINE", "icon": "chat",
                       "group": "connect", "needs_connect": True, "status": "soon",
                       "provider": "LINE", "pricing": _sub(39)},
    "email_triage": {"category": "เชื่อมบัญชี", "label": "คัดกรองอีเมล",
                     "blurb": "สรุปเมลด่วน ร่างตอบ", "icon": "mail",
                     "group": "connect", "needs_connect": True, "status": "soon",
                     "provider": "Google", "pricing": _sub(59)},
}


def enrich(entry: dict) -> dict:
    """Merge display + commerce copy onto a manifest entry. The DB row wins (so
    admin edits stick); DISPLAY only fills fields the entry doesn't carry."""
    base = dict(DISPLAY.get(entry.get("name", ""), {}))
    base.update({k: v for k, v in entry.items() if v is not None})
    return base
