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


def _once(amount):
    return {"tier": "onetime", "amount": amount, "currency": "THB"}


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
    # skills — free, by ปิ่น
    "morning_news": {"category": "ข่าวสาร", "label": "สรุปข่าวเช้า",
                     "blurb": "อ่านข่าวให้ทุกเช้า", "icon": "newspaper",
                     "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    "researcher": {"category": "ค้นคว้า", "label": "ค้นข้อมูลเชิงลึก",
                   "blurb": "หาหลายแหล่งแล้วสรุป", "icon": "brain",
                   "group": "ready", "provider": "ปิ่น", "pricing": _free()},
    # ดูดวง — the real working skill (thai_astrology); offered as a free trial.
    "thai_astrology": {"category": "ดูดวง", "status": "trial"},
    # account connects — coming soon (Gmail/LINE not wired yet).
    "line_assistant": {"category": "เชื่อมบัญชี", "label": "ผู้ช่วยผ่าน LINE",
                       "blurb": "คุยกับปิ่นผ่าน LINE · เตือนเข้า LINE", "icon": "chat",
                       "group": "connect", "needs_connect": True, "status": "soon",
                       "provider": "LINE", "pricing": _sub(39)},
    "email_triage": {"category": "เชื่อมบัญชี", "label": "คัดกรองอีเมล",
                     "blurb": "สรุปเมลด่วน ร่างตอบ", "icon": "mail",
                     "group": "connect", "needs_connect": True, "status": "soon",
                     "provider": "Google", "pricing": _sub(59)},
    "calendar_assistant": {"category": "เชื่อมบัญชี", "label": "ผู้ช่วยปฏิทิน",
                           "blurb": "หาเวลาว่าง สร้างนัด", "icon": "calendar",
                           "group": "connect", "needs_connect": True,
                           "provider": "Google", "pricing": _sub(59)},
    "notion_search": {"category": "เชื่อมบัญชี", "label": "ค้นใน Notion",
                      "blurb": "หาโน้ตของคุณ", "icon": "book",
                      "group": "connect", "needs_connect": True,
                      "provider": "Notion", "pricing": _sub(49)},
    "gcal_create_event": {"category": "เชื่อมบัญชี", "label": "สร้างนัดในปฏิทิน",
                          "blurb": "เพิ่มนัด Google", "icon": "calendar",
                          "group": "connect", "needs_connect": True,
                          "provider": "Google", "pricing": _sub(59)},
    "send_email": {"category": "เชื่อมบัญชี", "label": "ส่งอีเมล",
                   "blurb": "ส่งเมลให้", "icon": "mail",
                   "group": "connect", "needs_connect": True,
                   "provider": "Google", "pricing": _sub(59)},
}


def enrich(entry: dict) -> dict:
    """Merge display + commerce copy onto a manifest entry. The DB row wins (so
    admin edits stick); DISPLAY only fills fields the entry doesn't carry."""
    base = dict(DISPLAY.get(entry.get("name", ""), {}))
    base.update({k: v for k, v in entry.items() if v is not None})
    return base
