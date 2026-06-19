"""Tool catalog — the manifest list the device fetches at runtime to learn what
tools exist, without an app update. Each entry is blind metadata only:

    {name, kind, description, parameters (JSON-schema), argKeys}

`argKeys` is the PII allowlist the device enforces (it strips args to these keys
before any call). Hosted tools live in `tools.TOOLS`; MCP-fronted tools are
contributed by `mcp.manifests()`. No user content here — safe to cache/sign.
"""

from __future__ import annotations

from . import display, store

# Fallback manifests for the tools we host directly — only used if the DB is
# unavailable. The live source of truth is `store` (admin-editable).
_HOSTED = [
    {
        "name": "get_weather",
        "kind": "remote",
        "description": "ดูพยากรณ์อากาศของเมืองที่ระบุ",
        "parameters": {
            "type": "object",
            "properties": {
                "place": {"type": "string", "description": "ชื่อเมือง"},
                "days": {"type": "integer", "description": "จำนวนวัน 1-7"},
            },
            "required": ["place"],
        },
        "argKeys": ["place", "days"],
    },
    {
        "name": "get_currency",
        "kind": "remote",
        "description": "ดูอัตราแลกเปลี่ยน เช่น USD/THB",
        "parameters": {
            "type": "object",
            "properties": {
                "base": {"type": "string", "description": "สกุลฐาน"},
                "quote": {"type": "string", "description": "สกุลเทียบ"},
            },
        },
        "argKeys": ["base", "quote"],
    },
    {
        "name": "web_search",
        "kind": "remote",
        "description": "ค้นข้อมูลสด/ปัจจุบันจากเว็บ (ข่าว/ผลบอล/ราคา)",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "คำค้น"},
            },
            "required": ["query"],
        },
        "argKeys": ["query"],
    },
]


def manifests() -> list[dict]:
    """Full catalog from the DB (admin-editable): enabled hosted + MCP tools +
    skills, each enriched with consumer display copy. Falls back to built-in
    literals if the store can't be read."""
    try:
        entries = [
            *store.enabled_hosted_tools(),
            *store.enabled_mcp_tools(),
            *store.enabled_skills(),
            *store.enabled_subagents(),
        ]
        return [display.enrich(e) for e in entries]
    except Exception:  # noqa: BLE001
        return [display.enrich(e) for e in _HOSTED]
