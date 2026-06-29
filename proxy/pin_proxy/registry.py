"""Curated registry — vetted items an admin can install with one click, grouped
by category and tagged with their upstream source (attribution). Imported from:

  - MCP servers   → github.com/punkpeye/awesome-mcp-servers
  - skills        → github.com/VoltAgent/awesome-agent-skills
  - subagents     → github.com/VoltAgent/awesome-claude-code-subagents

Installing copies an entry into the DB (store); URLs/keys are placeholders to
fill per deployment.
"""

from __future__ import annotations

_AML_MCP = "awesome-mcp-servers"
_AML_SKILL = "awesome-agent-skills"
_AML_SUB = "awesome-claude-code-subagents"


def _obj(**props):
    return {"type": "object", "properties": props}


_S = {"type": "string"}

# --- MCP servers ------------------------------------------------------------
MCP = [
    {"name": "brave-search", "category": "ค้นหา", "url": "https://brave.mcp.host/mcp",
     "audited": True, "source": {"list": _AML_MCP, "repo": "modelcontextprotocol/servers"},
     "tools": [
         {"name": "web_search", "description": "ค้นเว็บ + ข่าวสด (Google)",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
         {"name": "news_search", "description": "ค้นข่าวล่าสุด",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
     ]},
    {"name": "memory", "category": "ความจำ", "url": "stdio://memory",
     "audited": True, "source": {"list": _AML_MCP, "repo": "modelcontextprotocol/servers"},
     "tools": [
         {"name": "create_entity", "description": "เพิ่ม entity ลง knowledge-graph",
          "parameters": _obj(name=_S, type=_S), "argKeys": ["name", "type"]},
         {"name": "search_nodes", "description": "ค้น node ใน graph",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
     ]},
    {"name": "google-maps", "category": "สถานที่", "url": "https://gmaps.mcp.host/mcp",
     "audited": True, "source": {"list": _AML_MCP, "repo": "modelcontextprotocol/servers"},
     "tools": [
         {"name": "geocode", "description": "แปลงสถานที่เป็นพิกัด",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
         {"name": "directions", "description": "เส้นทางระหว่างสองจุด",
          "parameters": _obj(origin=_S, destination=_S),
          "argKeys": ["origin", "destination"]},
     ]},
    {"name": "notion", "category": "ความรู้", "url": "https://notion.mcp.host/mcp",
     "audited": True, "source": {"list": _AML_MCP, "repo": "makenotion/notion-mcp"},
     "tools": [
         {"name": "notion_search", "description": "ค้นหน้าใน Notion",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
         {"name": "notion_append", "description": "เพิ่มเนื้อหาในหน้า",
          "parameters": _obj(page_id=_S, content=_S),
          "argKeys": ["page_id", "content"]},
     ]},
    {"name": "gcal", "category": "ปฏิทิน", "url": "stdio://google-calendar",
     "audited": True, "source": {"list": _AML_MCP, "repo": "modelcontextprotocol/servers"},
     "tools": [
         {"name": "gcal_create_event", "description": "สร้างนัด Google Calendar",
          "parameters": _obj(title=_S, start=_S, end=_S),
          "argKeys": ["title", "start", "end"]},
         {"name": "gcal_list", "description": "ดูนัดในช่วงเวลา",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
     ]},
    {"name": "gmail", "category": "สื่อสาร", "url": "https://gmail.mcp.host/mcp",
     "audited": False, "source": {"list": _AML_MCP, "repo": "gongrzhe/server-gmail"},
     "tools": [
         {"name": "send_email", "description": "ส่งอีเมล",
          "parameters": _obj(to=_S, subject=_S, body=_S),
          "argKeys": ["to", "subject", "body"]},
         {"name": "search_email", "description": "ค้นอีเมล",
          "parameters": _obj(query=_S), "argKeys": ["query"]},
     ]},
]

# --- skills -----------------------------------------------------------------
SKILLS = [
    {"name": "watch", "category": "ประสิทธิภาพ", "label": "ติดตามข่าว",
     "description": "ปิ่นคอยเฝ้าเรื่องที่สนใจ บอกเฉพาะตอนมีอะไรใหม่จริง",
     "instructions":
        "เมื่อผู้ใช้ขอให้ติดตามเรื่องไหน หรือบอกว่าอยากรู้เมื่อมีอะไรใหม่ → เรียก add_watch ทันที. "
        "เมื่อผู้ใช้ถาม/พูดถึงเรื่องเดิมตั้งแต่ 2 ครั้งขึ้นไป → เสนอสั้น ๆ ว่าจะเฝ้าให้ไหม "
        "('อยากให้คอยดูเรื่อง X แล้วบอกทุกเช้าไหม?') ตกลงค่อย add_watch. "
        "อย่าแอบสร้างเอง และอย่าเงียบทั้งที่ผู้ใช้สนใจซ้ำ ๆ ชัดเจน. "
        "ถ้าเรื่องกว้างไปจนค้นยาก ถามให้แคบลงก่อน.",
     "requires": {"tools": ["add_watch", "web_search", "recall_knowledge"]},
     "source": {"list": _AML_SKILL, "repo": "pin/watch"}},
    {"name": "morning_news", "category": "ประสิทธิภาพ", "description": "สรุปข่าวเช้า",
     "instructions": "ค้นข่าวล่าสุดแล้วสรุปเป็นหัวข้อสั้น พร้อมที่มา.",
     "requires": {"tools": ["web_search", "schedule_reminder"]},
     "source": {"list": _AML_SKILL, "repo": "pin/morning-news"}},
    {"name": "researcher", "category": "ค้นคว้า", "description": "ค้นคว้าเชิงลึก",
     "instructions": "งานที่ต้องค้นหลายรอบ ให้ delegate ไป researcher.",
     "requires": {"tools": ["delegate"]},
     "source": {"list": _AML_SKILL, "repo": "pin/researcher"}},
    {"name": "email_triage", "category": "อีเมล", "description": "คัดกรองอีเมล",
     "instructions": "อ่าน/จัดกลุ่มอีเมล สรุปอันด่วน ร่างตอบสั้น.",
     "requires": {"mcp": ["gmail"]},
     "source": {"list": _AML_SKILL, "repo": "google-workspace/gws-gmail"}},
    {"name": "calendar_assistant", "category": "ปฏิทิน", "description": "จัดตารางนัด",
     "instructions": "หาเวลาว่าง สร้างนัด เตือนล่วงหน้า.",
     "requires": {"mcp": ["gcal"], "tools": ["get_time"]},
     "source": {"list": _AML_SKILL, "repo": "google-workspace/gws-calendar"}},
]

# --- subagents --------------------------------------------------------------
SUBAGENTS = [
    {"name": "researcher", "category": "ค้นคว้า", "description": "ค้นคว้าเชิงลึกหลายแหล่ง",
     "system": "ค้นเว็บและความรู้ที่เก็บไว้หลายรอบ แล้วสรุปครบถ้วน ตรวจสอบได้. ห้ามมโน.",
     "toolNames": ["web_search", "recall_knowledge"], "model": "haiku", "maxSteps": 6,
     "source": {"list": _AML_SUB, "repo": "VoltAgent/awesome-claude-code-subagents"}},
    {"name": "trip-planner", "category": "ท่องเที่ยว", "description": "วางแผนทริป",
     "system": "หาเที่ยวบิน อากาศ สถานที่ แล้วร่างกำหนดการเป็นวัน ๆ.",
     "toolNames": ["get_weather", "get_currency"], "model": "sonnet", "maxSteps": 8,
     "source": {"list": _AML_SUB, "repo": "community/trip-planner"}},
    {"name": "planner", "category": "วางแผน", "description": "แตกงานใหญ่เป็นขั้นตอน",
     "system": "แยกงานเป็นสเตป ตั้งเตือนแต่ละขั้น สรุปแผน.",
     "toolNames": ["schedule_reminder", "remember_fact"], "model": "haiku", "maxSteps": 6,
     "source": {"list": _AML_SUB, "repo": "community/planner"}},
    {"name": "shopper", "category": "ช้อปปิ้ง", "description": "เทียบราคา/ตัวเลือก",
     "system": "เทียบราคาและรีวิวหลายแหล่ง แล้วสรุปตัวเลือกที่ดีที่สุด.",
     "toolNames": ["web_search", "get_currency"], "model": "haiku", "maxSteps": 6,
     "source": {"list": _AML_SUB, "repo": "community/shopper"}},
]
