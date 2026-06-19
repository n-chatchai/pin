"""SQLite store — the source of truth for the admin backoffice (catalog, skills,
subagents, MCP, published versions, admin users, blind logs).

Config-only: no user conversation/memory ever lands here. The proxy stays blind.
First run creates the schema and seeds it from the legacy hard-coded catalog +
`PIN_MCP_SERVERS` env, so existing behaviour is preserved.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time

_DB = os.environ.get("PIN_ADMIN_DB", os.path.expanduser("~/pin-admin.db"))

_SCHEMA = """
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
CREATE TABLE IF NOT EXISTS catalog_versions(
  version INTEGER PRIMARY KEY AUTOINCREMENT, signed_blob TEXT,
  published_at REAL, author TEXT, diff TEXT);
CREATE TABLE IF NOT EXISTS admin_users(
  email TEXT PRIMARY KEY, pw_hash TEXT, role TEXT);
CREATE TABLE IF NOT EXISTS tool_logs(
  ts REAL, tool TEXT, kind TEXT, arg_keys TEXT, status TEXT);
CREATE TABLE IF NOT EXISTS submissions(
  id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, name TEXT,
  payload_json TEXT, developer TEXT, status TEXT DEFAULT 'pending',
  note TEXT, created_at REAL);
"""

# Legacy hard-coded hosted tools — used to seed an empty DB.
_SEED_TOOLS = [
    ("get_weather", "remote", "ดูพยากรณ์อากาศของเมืองที่ระบุ",
     {"type": "object",
      "properties": {"place": {"type": "string", "description": "ชื่อเมือง"},
                     "days": {"type": "integer", "description": "จำนวนวัน 1-7"}},
      "required": ["place"]},
     ["place", "days"]),
    ("get_currency", "remote", "ดูอัตราแลกเปลี่ยน เช่น USD/THB",
     {"type": "object",
      "properties": {"base": {"type": "string"}, "quote": {"type": "string"}}},
     ["base", "quote"]),
    ("web_search", "remote", "ค้นข้อมูลสด/ปัจจุบันจากเว็บ",
     {"type": "object",
      "properties": {"query": {"type": "string", "description": "คำค้น"}},
      "required": ["query"]},
     ["query"]),
]


def conn() -> sqlite3.Connection:
    c = sqlite3.connect(_DB)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    return c


def init() -> None:
    """Create schema + migrate + seed on first run (idempotent)."""
    from . import display
    with conn() as c:
        c.executescript(_SCHEMA)
        # Migrate older DBs: add commerce/display columns if missing.
        _migrate = {
            "tools": ("label", "blurb", "category", "provider", "pricing_json",
                      "endpoint"),
            "skills": ("label", "provider", "pricing_json"),
            "subagents": ("label", "provider", "pricing_json"),
            "mcp_tools": ("label", "category", "provider", "pricing_json"),
        }
        for tbl, cols in _migrate.items():
            for col in cols:
                try:
                    c.execute(f"ALTER TABLE {tbl} ADD COLUMN {col} TEXT")
                except Exception:  # noqa: BLE001 — already present
                    pass
        if not c.execute("SELECT 1 FROM tools LIMIT 1").fetchone():
            for name, kind, desc, params, keys in _SEED_TOOLS:
                d = display.DISPLAY.get(name, {})
                c.execute(
                    "INSERT INTO tools(name,kind,description,parameters_json,"
                    "arg_keys_json,source,enabled,updated_at,label,blurb,"
                    "category,provider,pricing_json) "
                    "VALUES(?,?,?,?,?,?,1,?,?,?,?,?,?)",
                    (name, kind, desc, json.dumps(params), json.dumps(keys),
                     "hosted", time.time(), d.get("label"), d.get("blurb"),
                     d.get("category"), d.get("provider"),
                     json.dumps(d["pricing"]) if d.get("pricing") else None))
        # Seed MCP from env once (PIN_MCP_SERVERS) if no servers configured yet.
        if not c.execute("SELECT 1 FROM mcp_servers LIMIT 1").fetchone():
            _seed_mcp_from_env(c)


def _seed_mcp_from_env(c: sqlite3.Connection) -> None:
    raw = os.environ.get("PIN_MCP_SERVERS", "").strip()
    if not raw:
        return
    try:
        for srv in json.loads(raw):
            c.execute(
                "INSERT OR REPLACE INTO mcp_servers(name,url,headers_json,status)"
                " VALUES(?,?,?,?)",
                (srv["name"], srv["url"], json.dumps(srv.get("headers") or {}),
                 "configured"))
            for t in srv.get("tools", []):
                c.execute(
                    "INSERT OR REPLACE INTO mcp_tools(server,name,description,"
                    "parameters_json,arg_keys_json,enabled) VALUES(?,?,?,?,?,1)",
                    (srv["name"], t["name"], t.get("description", ""),
                     json.dumps(t.get("parameters", {})),
                     json.dumps(t.get("argKeys", []))))
    except Exception:  # noqa: BLE001
        pass


# ---- reads used by the catalog / MCP layers --------------------------------

def _tool_dict(r) -> dict:
    out = {
        "name": r["name"], "kind": r["kind"], "description": r["description"],
        "parameters": json.loads(r["parameters_json"] or "{}"),
        "argKeys": json.loads(r["arg_keys_json"] or "[]"),
        "label": r["label"], "blurb": r["blurb"], "category": r["category"],
        "provider": r["provider"],
        "pricing": json.loads(r["pricing_json"]) if r["pricing_json"] else None,
    }
    return {k: v for k, v in out.items() if v is not None}


def enabled_hosted_tools() -> list[dict]:
    with conn() as c:
        rows = c.execute(
            "SELECT * FROM tools WHERE enabled=1 AND kind!='mcp'").fetchall()
    return [_tool_dict(r) for r in rows]


def get_tool(name: str):
    with conn() as c:
        return c.execute("SELECT * FROM tools WHERE name=?", (name,)).fetchone()


def remote_endpoint(name: str) -> str | None:
    """A third-party-hosted tool's URL (dev's server), or None for built-ins."""
    with conn() as c:
        r = c.execute(
            "SELECT endpoint FROM tools WHERE name=? AND enabled=1",
            (name,)).fetchone()
    return r["endpoint"] if r and r["endpoint"] else None


def update_tool_meta(name: str, label: str, blurb: str, category: str,
                     provider: str, tier: str, amount: str, period: str) -> None:
    pricing = {"tier": tier or "free"}
    if tier in ("onetime", "subscription") and amount:
        pricing["amount"] = int(amount)
        pricing["currency"] = "THB"
        if tier == "subscription":
            pricing["period"] = period or "month"
    with conn() as c:
        c.execute("UPDATE tools SET label=?,blurb=?,category=?,provider=?,"
                  "pricing_json=?,updated_at=? WHERE name=?",
                  (label or None, blurb or None, category or None,
                   provider or None, json.dumps(pricing), time.time(), name))


def _extra(r) -> dict:
    """Optional display/commerce fields if the column has a value."""
    out = {}
    for k in ("label", "provider", "category"):
        if k in r.keys() and r[k]:
            out[k] = r[k]
    if "pricing_json" in r.keys() and r["pricing_json"]:
        out["pricing"] = json.loads(r["pricing_json"])
    return out


def enabled_mcp_tools() -> list[dict]:
    with conn() as c:
        rows = c.execute(
            "SELECT * FROM mcp_tools WHERE enabled=1").fetchall()
    return [{
        "name": r["name"], "kind": "mcp", "description": r["description"],
        "parameters": json.loads(r["parameters_json"] or "{}"),
        "argKeys": json.loads(r["arg_keys_json"] or "[]"),
        "server": r["server"], **_extra(r),
    } for r in rows]


def enabled_skills() -> list[dict]:
    with conn() as c:
        rows = c.execute("SELECT * FROM skills WHERE enabled=1").fetchall()
    return [{
        "name": r["name"], "kind": "skill", "description": r["description"],
        "instructions": r["instructions"],
        "requires": json.loads(r["requires_json"] or "{}"), **_extra(r),
    } for r in rows]


def enabled_subagents() -> list[dict]:
    with conn() as c:
        rows = c.execute("SELECT * FROM subagents").fetchall()
    return [{
        "name": r["name"], "kind": "subagent", "description": r["description"],
        "system": r["system"],
        "toolNames": json.loads(r["tool_names_json"] or "[]"),
        "model": r["model"], "maxSteps": r["max_steps"], **_extra(r),
    } for r in rows]


def mcp_index() -> dict[str, dict]:
    """tool_name -> {server cfg, tool cfg} for routing /tool/{name}."""
    out: dict[str, dict] = {}
    with conn() as c:
        servers = {s["name"]: s for s in c.execute("SELECT * FROM mcp_servers")}
        for t in c.execute("SELECT * FROM mcp_tools WHERE enabled=1"):
            s = servers.get(t["server"])
            if not s:
                continue
            out[t["name"]] = {
                "server": {"name": s["name"], "url": s["url"],
                           "headers": json.loads(s["headers_json"] or "{}")},
                "tool": {"name": t["name"]},
            }
    return out


# ---- installs from the curated registry ------------------------------------

def installed_names(table: str) -> set[str]:
    with conn() as c:
        return {r[0] for r in c.execute(f"SELECT name FROM {table}")}


def uninstall_mcp(name: str) -> None:
    with conn() as c:
        c.execute("DELETE FROM mcp_tools WHERE server=?", (name,))
        c.execute("DELETE FROM mcp_servers WHERE name=?", (name,))


def uninstall_skill(name: str) -> None:
    with conn() as c:
        c.execute("DELETE FROM skills WHERE name=?", (name,))


def uninstall_subagent(name: str) -> None:
    with conn() as c:
        c.execute("DELETE FROM subagents WHERE name=?", (name,))


def _src(item: dict) -> str:
    s = item.get("source") or {}
    return " · ".join(x for x in (s.get("list"), s.get("repo")) if x)


def _pj(item: dict):
    p = item.get("pricing")
    return json.dumps(p) if p else None


def install_mcp(srv: dict) -> None:
    with conn() as c:
        c.execute("INSERT OR REPLACE INTO mcp_servers(name,url,headers_json,"
                  "status,category,source) VALUES(?,?,?,?,?,?)",
                  (srv["name"], srv["url"], json.dumps(srv.get("headers") or {}),
                   "audited" if srv.get("audited") else "review",
                   srv.get("category", ""), _src(srv)))
        prov = srv.get("provider")
        for t in srv.get("tools", []):
            c.execute("INSERT OR REPLACE INTO mcp_tools(server,name,description,"
                      "parameters_json,arg_keys_json,enabled,label,category,"
                      "provider,pricing_json) VALUES(?,?,?,?,?,1,?,?,?,?)",
                      (srv["name"], t["name"], t.get("description", ""),
                       json.dumps(t.get("parameters", {})),
                       json.dumps(t.get("argKeys", [])),
                       t.get("label"), srv.get("category"),
                       t.get("provider") or prov, _pj(t) or _pj(srv)))


def install_tool(t: dict) -> None:
    """A developer-hosted remote tool (has an `endpoint` URL we route to)."""
    with conn() as c:
        c.execute(
            "INSERT OR REPLACE INTO tools(name,kind,description,parameters_json,"
            "arg_keys_json,source,enabled,updated_at,label,blurb,category,"
            "provider,pricing_json,endpoint) VALUES(?,?,?,?,?,?,1,?,?,?,?,?,?,?)",
            (t["name"], t.get("kind", "remote"), t.get("description", ""),
             json.dumps(t.get("parameters") or {"type": "object",
                                                 "properties": {}}),
             json.dumps(t.get("argKeys", [])), "dev", time.time(),
             t.get("label"), t.get("blurb"), t.get("category"),
             t.get("provider"), _pj(t), t.get("endpoint")))


def install_skill(s: dict) -> None:
    with conn() as c:
        c.execute("INSERT OR REPLACE INTO skills(name,description,instructions,"
                  "requires_json,enabled,category,source,label,provider,"
                  "pricing_json) VALUES(?,?,?,?,1,?,?,?,?,?)",
                  (s["name"], s.get("description", ""), s.get("instructions", ""),
                   json.dumps(s.get("requires", {})), s.get("category", ""),
                   _src(s), s.get("label"), s.get("provider"), _pj(s)))


def install_subagent(s: dict) -> None:
    with conn() as c:
        c.execute("INSERT OR REPLACE INTO subagents(name,description,system,"
                  "tool_names_json,model,max_steps,category,source,label,"
                  "provider,pricing_json) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                  (s["name"], s.get("description", ""), s.get("system", ""),
                   json.dumps(s.get("toolNames", [])), s.get("model", ""),
                   s.get("maxSteps", 6), s.get("category", ""), _src(s),
                   s.get("label"), s.get("provider"), _pj(s)))


# ---- developer submissions + review queue ----------------------------------

def add_submission(type_: str, name: str, payload: dict, developer: str) -> int:
    with conn() as c:
        cur = c.execute(
            "INSERT INTO submissions(type,name,payload_json,developer,status,"
            "created_at) VALUES(?,?,?,?, 'pending', ?)",
            (type_, name, json.dumps(payload), developer, time.time()))
        return cur.lastrowid


def list_submissions(status: str | None = None) -> list[dict]:
    with conn() as c:
        if status:
            rows = c.execute("SELECT * FROM submissions WHERE status=?"
                             " ORDER BY id DESC", (status,)).fetchall()
        else:
            rows = c.execute("SELECT * FROM submissions ORDER BY id DESC"
                             ).fetchall()
    return [dict(r) for r in rows]


def get_submission(sub_id: int):
    with conn() as c:
        return c.execute("SELECT * FROM submissions WHERE id=?",
                         (sub_id,)).fetchone()


def set_submission_status(sub_id: int, status: str, note: str = "") -> None:
    with conn() as c:
        c.execute("UPDATE submissions SET status=?,note=? WHERE id=?",
                  (status, note, sub_id))


_FORBIDDEN_ARGKEYS = {
    "identity", "conversation", "convo", "prefs", "preferences", "user",
    "email", "token", "secret", "password", "name", "phone", "address",
    "userid", "user_id", "history",
}


def audit_submission(type_: str, payload: dict) -> list[dict]:
    """Automated checks before review: forbidden argKeys (block), missing
    declarations (warn). Returns [{level, msg}]."""
    issues: list[dict] = []

    def check_keys(keys, where):
        for k in keys or []:
            if str(k).lower() in _FORBIDDEN_ARGKEYS:
                issues.append({"level": "block",
                               "msg": f"argKey ต้องห้าม ({where}): {k}"})

    if type_ == "mcp":
        for t in payload.get("tools", []):
            ak = t.get("argKeys")
            if not ak and (t.get("parameters", {}) or {}).get("properties"):
                issues.append({"level": "warn",
                               "msg": f"{t.get('name')}: ไม่ประกาศ argKeys"})
            check_keys(ak, t.get("name", "tool"))
    elif type_ == "skill":
        if not payload.get("instructions"):
            issues.append({"level": "warn", "msg": "ไม่มี instructions"})
    elif type_ == "subagent":
        if not payload.get("system"):
            issues.append({"level": "warn", "msg": "ไม่มี system prompt"})
        if not payload.get("toolNames"):
            issues.append({"level": "warn", "msg": "ไม่ได้ระบุ toolNames"})
    elif type_ == "tool":
        if not payload.get("endpoint"):
            issues.append({"level": "block", "msg": "ไม่มี endpoint (URL)"})
        if not payload.get("argKeys"):
            issues.append({"level": "warn", "msg": "ไม่ได้ประกาศ argKeys"})
        check_keys(payload.get("argKeys"), "tool")
    return issues


def approve_submission(sub_id: int) -> bool:
    """Approve = install the submitted capability into the live catalog tables."""
    with conn() as c:
        r = c.execute("SELECT * FROM submissions WHERE id=?",
                      (sub_id,)).fetchone()
    if r is None:
        return False
    payload = json.loads(r["payload_json"] or "{}")
    {"mcp": install_mcp, "skill": install_skill,
     "subagent": install_subagent,
     "tool": install_tool}.get(r["type"], lambda _: None)(payload)
    set_submission_status(sub_id, "approved")
    return True


def log_tool(tool: str, kind: str, arg_keys: list[str], status: str) -> None:
    with conn() as c:
        c.execute("INSERT INTO tool_logs(ts,tool,kind,arg_keys,status)"
                  " VALUES(?,?,?,?,?)",
                  (time.time(), tool, kind, ",".join(arg_keys), status))
