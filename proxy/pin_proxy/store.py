"""SQLite store — the source of truth for the admin backoffice (catalog, skills,
subagents, MCP, capability requests, waitlist, blind logs).

Config-only: no user conversation/memory ever lands here. The proxy stays blind.
First run creates the schema and seeds it from the legacy hard-coded catalog +
`PIN_MCP_SERVERS` env, so existing behaviour is preserved.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time

_DB = os.environ.get("PIN_DB", os.path.expanduser("~/pin.db"))

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
                      "endpoint", "status", "config_json", "render", "ask_params"),
            "skills": ("label", "provider", "pricing_json", "category", "status"),
            "subagents": ("label", "provider", "pricing_json", "category",
                          "status"),
            "mcp_tools": ("label", "category", "provider", "pricing_json",
                          "defaults_json", "status", "render", "ask_params"),
            "waitlist": ("sent_at", "unsubscribed_at"),
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
        _seed_paid(c)


# Paid capabilities for the store (idempotent — INSERT OR IGNORE by name). These
# are the first products: a ดูดวง flagship + two account connects. Display copy
# (icon/group/blurb) lives in display.py; pricing/category travel on the row.
_SEED_PAID = [
    # ดูดวง is provided by the existing thai_astrology skill (real, working) — no
    # separate seed; display.py just marks it a free trial.
    {"name": "email_triage", "label": "คัดกรองอีเมล", "category": "เชื่อมบัญชี",
     "provider": "Google", "description": "สรุปเมลด่วน ร่างตอบให้",
     "pricing": {"tier": "subscription", "amount": 59, "currency": "THB",
                 "period": "month"}, "instructions": ""},
    {"name": "line_assistant", "label": "ผู้ช่วยผ่าน LINE", "category": "เชื่อมบัญชี",
     "provider": "LINE", "description": "คุยกับปิ่นผ่าน LINE + เตือนเข้า LINE",
     "pricing": {"tier": "subscription", "amount": 39, "currency": "THB",
                 "period": "month"}, "instructions": ""},
]


def _seed_paid(c: sqlite3.Connection) -> None:
    for s in _SEED_PAID:
        c.execute(
            "INSERT OR IGNORE INTO skills(name,description,instructions,"
            "requires_json,enabled,category,source,label,provider,pricing_json)"
            " VALUES(?,?,?,?,1,?,?,?,?,?)",
            (s["name"], s["description"], s["instructions"], "{}",
             s["category"], "hosted", s["label"], s["provider"],
             json.dumps(s["pricing"])))


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
    cols = r.keys()
    cfg = r["config_json"] if "config_json" in cols else None
    out = {
        "name": r["name"], "kind": r["kind"], "description": r["description"],
        "parameters": json.loads(r["parameters_json"] or "{}"),
        "argKeys": json.loads(r["arg_keys_json"] or "[]"),
        "label": r["label"], "blurb": r["blurb"], "category": r["category"],
        "provider": r["provider"],
        "pricing": json.loads(r["pricing_json"]) if r["pricing_json"] else None,
        # Admin-set tool config (e.g. news_reporter RSS feeds) — ships in the
        # catalog manifest so the on-device tool reads it like its params.
        "config": json.loads(cfg) if cfg else None,
        # Preferred rendering of the result on the device: auto | card | text.
        "render": r["render"] if "render" in cols else None,
        # Params the model must get from the user before calling (e.g. an enum
        # like ดูดวง system=thai/bazi) — stored comma-separated, shipped as a list.
        "askParams": _split_csv(r["ask_params"]) if "ask_params" in cols else None,
    }
    return {k: v for k, v in out.items() if v is not None}


def _split_csv(s) -> list | None:
    if not s:
        return None
    parts = [p.strip() for p in str(s).split(",") if p.strip()]
    return parts or None


def get_tool_config(name: str) -> dict:
    with conn() as c:
        r = c.execute("SELECT config_json FROM tools WHERE name=?",
                      (name,)).fetchone()
    return json.loads(r["config_json"]) if r and r["config_json"] else {}


def set_tool_config(name: str, config: dict) -> None:
    with conn() as c:
        c.execute("UPDATE tools SET config_json=?,updated_at=? WHERE name=?",
                  (json.dumps(config), time.time(), name))


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
    for k in ("label", "provider", "category", "status", "render"):
        if k in r.keys() and r[k]:
            out[k] = r[k]
    if "ask_params" in r.keys() and r["ask_params"]:
        ap = _split_csv(r["ask_params"])
        if ap:
            out["askParams"] = ap
    if "pricing_json" in r.keys() and r["pricing_json"]:
        out["pricing"] = json.loads(r["pricing_json"])
    return out


# ---- store (capability) management across all catalog tables -----------------
# Internal/plumbing tools that are never user-facing capabilities (privacy/admin
# helpers the agent calls, not things a user "turns on").
_INTERNAL_CAPS = {"forget_end_user", "get_transits"}


def all_capabilities() -> list[dict]:
    """Every user-facing capability (enabled OR not), enriched with display copy,
    for the admin store. Subagents are internal (delegate-only) and excluded;
    so are plumbing tools in _INTERNAL_CAPS."""
    from . import display
    out = []
    with conn() as c:
        for tbl, kind in (("tools", "tool"), ("skills", "skill"),
                          ("mcp_tools", "mcp")):
            cols = {d[1] for d in c.execute(f"PRAGMA table_info({tbl})")}
            for r in c.execute(f"SELECT * FROM {tbl}"):
                if r["name"] in _INTERNAL_CAPS:
                    continue
                d = {"name": r["name"], "kind": kind,
                     "enabled": bool(r["enabled"]) if "enabled" in cols else True,
                     "description": r["description"] if "description" in cols else "",
                     **_extra(r)}
                if "server" in cols:
                    d["server"] = r["server"]
                out.append(display.enrich(d))
    return out


def toggle_capability(name: str) -> None:
    with conn() as c:
        for tbl in ("tools", "skills", "mcp_tools"):
            if c.execute(f"SELECT 1 FROM {tbl} WHERE name=? LIMIT 1",
                         (name,)).fetchone():
                c.execute(f"UPDATE {tbl} SET enabled=1-enabled WHERE name=?",
                          (name,))
                return


def set_store_meta(name: str, category: str | None = None,
                   status: str | None = None, tier: str | None = None,
                   amount: str | None = None, period: str = "month",
                   render: str | None = None,
                   ask_params: str | None = None) -> None:
    """Set the store-facing fields (category / status / pricing / render) for a
    capability, whichever catalog table it lives in."""
    with conn() as c:
        for tbl in ("tools", "skills", "subagents", "mcp_tools"):
            if not c.execute(f"SELECT 1 FROM {tbl} WHERE name=? LIMIT 1",
                             (name,)).fetchone():
                continue
            sets, vals = [], []
            if category is not None:
                sets.append("category=?"); vals.append(category)
            if status is not None:
                sets.append("status=?"); vals.append(status)
            # render / ask_params only exist on tools/mcp_tools; skip elsewhere.
            if render is not None and tbl in ("tools", "mcp_tools"):
                sets.append("render=?"); vals.append(render or None)
            if ask_params is not None and tbl in ("tools", "mcp_tools"):
                sets.append("ask_params=?"); vals.append(ask_params or None)
            if tier is not None:
                pricing = {"tier": tier or "free", "currency": "THB"}
                if tier in ("onetime", "subscription") and amount:
                    pricing["amount"] = int(amount)
                if tier == "subscription":
                    pricing["period"] = period or "month"
                sets.append("pricing_json=?"); vals.append(json.dumps(pricing))
            if sets:
                vals.append(name)
                c.execute(f"UPDATE {tbl} SET {','.join(sets)} WHERE name=?", vals)
            return


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
                "tool": {"name": t["name"],
                         "defaults": json.loads(t["defaults_json"] or "{}")},
            }
    return out


# ---- installs from the curated registry ------------------------------------

def installed_names(table: str) -> set[str]:
    with conn() as c:
        return {r[0] for r in c.execute(f"SELECT name FROM {table}")}


def mcp_tools_for_server(server: str) -> list[dict]:
    """A server's tools with their param names (from the MCP schema) + the
    admin-configured defaults — for the defaults editor."""
    with conn() as c:
        rows = c.execute(
            "SELECT name,description,label,parameters_json,defaults_json "
            "FROM mcp_tools WHERE server=?", (server,)).fetchall()
    out = []
    for r in rows:
        props = (json.loads(r["parameters_json"] or "{}").get("properties") or {})
        defaults = json.loads(r["defaults_json"] or "{}")
        params = [{"key": k, "desc": v.get("description") or v.get("title") or ""}
                  for k, v in props.items()]
        # Also surface params that exist only as a default (proxy-injected, e.g.
        # end_user_ref) so the admin can see/edit them.
        seen = {p["key"] for p in params}
        for k in defaults:
            if k not in seen:
                params.append({"key": k, "desc": "(ฉีดโดย proxy)"})
        out.append({
            "name": r["name"], "label": r["label"] or r["name"],
            "description": r["description"], "params": params, "defaults": defaults,
        })
    return out


def set_mcp_defaults(name: str, defaults: dict) -> None:
    with conn() as c:
        c.execute("UPDATE mcp_tools SET defaults_json=? WHERE name=?",
                  (json.dumps(defaults), name))


def get_mcp_server(name: str) -> dict | None:
    with conn() as c:
        r = c.execute("SELECT name,url,headers_json FROM mcp_servers WHERE name=?",
                      (name,)).fetchone()
    return None if not r else {
        "name": r["name"], "url": r["url"],
        "headers": json.loads(r["headers_json"] or "{}")}


def refresh_mcp_tool(server: str, name: str, description: str,
                     parameters: dict, arg_keys: list) -> bool:
    """Update a tool's SCHEMA (description/params/argKeys) from a live tools/list,
    preserving admin-set display/pricing/status/defaults. Returns True if new."""
    with conn() as c:
        exists = c.execute("SELECT 1 FROM mcp_tools WHERE name=?",
                           (name,)).fetchone()
        if exists:
            # Keep the admin-curated description (it carries agent guidance like
            # "ask which system"); only the live schema refreshes.
            c.execute("UPDATE mcp_tools SET parameters_json=?,arg_keys_json=? "
                      "WHERE name=?",
                      (json.dumps(parameters), json.dumps(arg_keys), name))
            return False
        c.execute("INSERT INTO mcp_tools(server,name,description,parameters_json,"
                  "arg_keys_json,enabled,defaults_json) VALUES(?,?,?,?,?,1,'{}')",
                  (server, name, description, json.dumps(parameters),
                   json.dumps(arg_keys)))
        return True


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
                      "provider,pricing_json,defaults_json) "
                      "VALUES(?,?,?,?,?,1,?,?,?,?,?)",
                      (srv["name"], t["name"], t.get("description", ""),
                       json.dumps(t.get("parameters", {})),
                       json.dumps(t.get("argKeys", [])),
                       t.get("label"), srv.get("category"),
                       t.get("provider") or prov, _pj(t) or _pj(srv),
                       json.dumps(t.get("defaults") or {})))


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


# ---- capability requests (backlog) -----------------------------------------

def add_capability_request(capability: str, detail: str, user: str) -> None:
    """Log a user's request for a not-yet-supported capability. Dedupe by
    capability (case-insensitive): bump the count + track distinct requesters."""
    cap = capability.strip()
    if not cap:
        return
    now = time.time()
    with conn() as c:
        row = c.execute(
            "SELECT id,count,requesters FROM capability_requests"
            " WHERE lower(capability)=lower(?)", (cap,)).fetchone()
        if row:
            users = set(json.loads(row["requesters"] or "[]"))
            users.add(user)
            c.execute(
                "UPDATE capability_requests SET count=?,requesters=?,"
                "updated_at=?,detail=COALESCE(NULLIF(?,''),detail) WHERE id=?",
                (len(users), json.dumps(sorted(users)), now, detail, row["id"]))
        else:
            c.execute(
                "INSERT INTO capability_requests(capability,detail,status,count,"
                "requesters,created_at,updated_at) VALUES(?,?, 'requested', 1,?,?,?)",
                (cap, detail, json.dumps([user]), now, now))


def list_capability_requests() -> list[dict]:
    with conn() as c:
        rows = c.execute(
            "SELECT * FROM capability_requests ORDER BY count DESC, updated_at DESC"
        ).fetchall()
    return [dict(r) for r in rows]


def set_capability_status(req_id: int, status: str) -> None:
    with conn() as c:
        c.execute("UPDATE capability_requests SET status=?,updated_at=? WHERE id=?",
                  (status, time.time(), req_id))


def add_waitlist(email: str, use: str, source: str = "site") -> None:
    """Pre-launch signup from the marketing site. Dedupe by email (keep the
    latest chosen use). No conversation content — just email + use-case."""
    em = email.strip().lower()
    if not em:
        return
    with conn() as c:
        c.execute(
            "INSERT INTO waitlist(email,use,source,created_at) VALUES(?,?,?,?)"
            " ON CONFLICT(email) DO UPDATE SET use=excluded.use,"
            "created_at=excluded.created_at",
            (em, use.strip(), source, time.time()))


def list_waitlist() -> list[dict]:
    with conn() as c:
        return [dict(r) for r in c.execute(
            "SELECT * FROM waitlist ORDER BY created_at DESC").fetchall()]


def mark_waitlist_sent(email: str) -> None:
    with conn() as c:
        c.execute("UPDATE waitlist SET sent_at=? WHERE email=?",
                  (time.time(), email))


def mark_waitlist_unsubscribed(email: str) -> None:
    with conn() as c:
        c.execute("UPDATE waitlist SET unsubscribed_at=? WHERE email=?",
                  (time.time(), email))


# ---- mail threads (waitlist outreach + captured replies) -------------------

def add_mail_message(waitlist_email: str, direction: str, subject: str,
                     body: str, msg_id: str = "", in_reply_to: str = "") -> None:
    with conn() as c:
        c.execute("INSERT INTO mail_messages(waitlist_email,direction,subject,"
                  "body,msg_id,in_reply_to,created_at) VALUES(?,?,?,?,?,?,?)",
                  (waitlist_email, direction, subject, body, msg_id,
                   in_reply_to, time.time()))


def mail_thread(email: str) -> list[dict]:
    with conn() as c:
        return [dict(r) for r in c.execute(
            "SELECT * FROM mail_messages WHERE waitlist_email=?"
            " ORDER BY created_at", (email,)).fetchall()]


def mail_reply_counts() -> dict:
    """email -> number of inbound replies captured (for the list view)."""
    with conn() as c:
        return {r["waitlist_email"]: r["n"] for r in c.execute(
            "SELECT waitlist_email, COUNT(*) n FROM mail_messages"
            " WHERE direction='in' GROUP BY waitlist_email").fetchall()}


def mail_out_index() -> dict:
    """sent Message-ID -> waitlist_email, to match inbound In-Reply-To."""
    with conn() as c:
        return {r["msg_id"]: r["waitlist_email"] for r in c.execute(
            "SELECT msg_id,waitlist_email FROM mail_messages"
            " WHERE direction='out' AND msg_id!=''").fetchall()}


def mail_msgid_seen(msg_id: str) -> bool:
    if not msg_id:
        return False
    with conn() as c:
        return c.execute("SELECT 1 FROM mail_messages WHERE msg_id=? LIMIT 1",
                         (msg_id,)).fetchone() is not None


def waitlist_email_set() -> set:
    with conn() as c:
        return {r["email"] for r in
                c.execute("SELECT email FROM waitlist").fetchall()}


def record_push_device(user_id: str, device: str, platform: str) -> None:
    """Remember which push token (FCM/APNs) reaches a given Matrix user, so the
    admin can see who's wakeable and a future broadcast can target them. Upsert
    by user_id — the latest token wins (tokens rotate)."""
    if not (user_id and device):
        return
    with conn() as c:
        c.execute(
            "INSERT INTO push_devices(user_id,device,platform,updated_at) "
            "VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET "
            "device=excluded.device, platform=excluded.platform, "
            "updated_at=excluded.updated_at",
            (user_id, device, platform, time.time()))


def list_push_devices() -> list[dict]:
    with conn() as c:
        return [dict(r) for r in c.execute(
            "SELECT * FROM push_devices ORDER BY updated_at DESC").fetchall()]


def log_tool(tool: str, kind: str, arg_keys: list[str], status: str) -> None:
    with conn() as c:
        c.execute("INSERT INTO tool_logs(ts,tool,kind,arg_keys,status)"
                  " VALUES(?,?,?,?,?)",
                  (time.time(), tool, kind, ",".join(arg_keys), status))
