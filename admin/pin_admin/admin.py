"""Admin backoffice — HTMX + Jinja, server-rendered, owner-only. Manages the
catalog/skills/MCP/subagents config and publishes a signed catalog snapshot.

Auth uses tuwunel (Matrix): the admin logs in with their ปิ่น account; we
exchange username/password for a homeserver access token, keep it in an
httpOnly cookie, and validate it via `whoami` on each request. Owners (full
backoffice) are listed in PIN_ADMIN_OWNERS; everyone else is a developer.
Manages config only — never user content.
"""

from __future__ import annotations

import base64
import json
import os
import time

import httpx
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from pin_proxy import registry, store

_HERE = os.path.dirname(__file__)
templates = Jinja2Templates(directory=os.path.join(_HERE, "templates"))
templates.env.filters["fromjson"] = lambda s: json.loads(s or "[]")
router = APIRouter(prefix="/admin", tags=["admin"])

_COOKIE = "pin_admin"
_HOMESERVER = os.environ.get(
    "PIN_HOMESERVER", "http://127.0.0.1:6167").rstrip("/")
# Owners get the full backoffice; everyone else lands in the developer portal.
# Comma-separated @user:domain or bare localparts.
_OWNERS = {s.strip() for s in os.environ.get("PIN_ADMIN_OWNERS", "").split(",")
           if s.strip()}
_WHOAMI_TTL = 300.0
_whoami_cache: dict[str, tuple[str, float]] = {}


# ---- auth ------------------------------------------------------------------

def _whoami(token: str) -> str | None:
    """Resolve a tuwunel access token → user_id (cached). None if invalid."""
    if not token:
        return None
    now = time.monotonic()
    hit = _whoami_cache.get(token)
    if hit and hit[1] > now:
        return hit[0]
    try:
        r = httpx.get(f"{_HOMESERVER}/_matrix/client/v3/account/whoami",
                      headers={"Authorization": f"Bearer {token}"}, timeout=5.0)
    except Exception:  # noqa: BLE001
        return None
    if r.status_code != 200:
        _whoami_cache.pop(token, None)
        return None
    uid = r.json().get("user_id", "")
    _whoami_cache[token] = (uid, now + _WHOAMI_TTL)
    return uid


def _matrix_login(user: str, password: str) -> str | None:
    """Password-login against tuwunel → access_token (None on failure)."""
    local = user.split(":")[0].lstrip("@")
    try:
        r = httpx.post(f"{_HOMESERVER}/_matrix/client/v3/login", timeout=8.0,
                       json={"type": "m.login.password",
                             "identifier": {"type": "m.id.user", "user": local},
                             "password": password})
    except Exception:  # noqa: BLE001
        return None
    return r.json().get("access_token") if r.status_code == 200 else None


def _is_owner(user_id: str) -> bool:
    local = user_id.split(":")[0].lstrip("@")
    return user_id in _OWNERS or local in _OWNERS


def _auth(request: Request, login_path: str) -> str:
    """Validate the cookie token via whoami → user_id, else 303 to login."""
    uid = _whoami(request.cookies.get(_COOKIE) or "")
    if not uid:
        raise HTTPException(status_code=303, detail="login",
                            headers={"Location": login_path})
    return uid


def current_admin(request: Request) -> str:
    """Any logged-in user (owner or developer)."""
    return _auth(request, "/admin/login")


def owner(request: Request) -> str:
    """Owner-only routes; non-owners are bounced to the developer portal."""
    uid = _auth(request, "/admin/login")
    if not _is_owner(uid):
        raise HTTPException(status_code=303, detail="dev",
                            headers={"Location": "/developers"})
    return uid


@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    return templates.TemplateResponse(request, "login.html")


@router.post("/login")
def login(request: Request, email: str = Form(...), password: str = Form(...)):
    token = _matrix_login(email, password)
    if not token:
        return templates.TemplateResponse(
            request, "login.html", {"error": "เข้าสู่ระบบไม่สำเร็จ"})
    dest = "/admin" if _is_owner(_whoami(token) or "") else "/developers"
    resp = RedirectResponse(dest, status_code=303)
    resp.set_cookie(_COOKIE, token, httponly=True, samesite="lax",
                    max_age=8 * 3600)
    return resp


@router.post("/logout")
def logout():
    resp = RedirectResponse("/admin/login", status_code=303)
    resp.delete_cookie(_COOKIE)
    return resp


# ════════════════════════════════════════════════════════════════════════
# Developer portal — separate URL space (/developers), its own login/signup.
# ════════════════════════════════════════════════════════════════════════
dev_router = APIRouter(prefix="/developers", tags=["developers"])


def current_dev(request: Request) -> str:
    """Any logged-in ปิ่น user; unauthenticated → the developer login."""
    return _auth(request, "/developers/login")


@dev_router.get("/login", response_class=HTMLResponse)
def dev_login_page(request: Request):
    return templates.TemplateResponse(
        request, "login.html",
        {"post": "/developers/login", "title": "Developer"})


@dev_router.post("/login")
def dev_login(request: Request, email: str = Form(...),
              password: str = Form(...)):
    token = _matrix_login(email, password)
    if not token:
        return templates.TemplateResponse(
            request, "login.html",
            {"error": "เข้าสู่ระบบไม่สำเร็จ", "post": "/developers/login",
             "title": "Developer"})
    resp = RedirectResponse("/developers", status_code=303)
    resp.set_cookie(_COOKIE, token, httponly=True, samesite="lax",
                    max_age=8 * 3600)
    return resp


@dev_router.post("/logout")
def dev_logout():
    resp = RedirectResponse("/developers/login", status_code=303)
    resp.delete_cookie(_COOKIE)
    return resp


@dev_router.get("", response_class=HTMLResponse)
def dev_portal(request: Request, dev: str = Depends(current_dev)):
    mine = [s for s in store.list_submissions() if s["developer"] == dev]
    return templates.TemplateResponse(
        request, "dev.html", {"admin": dev, "mine": mine})


@dev_router.get("/sub/{sub_id}", response_class=HTMLResponse)
def dev_sub_detail(sub_id: int, request: Request,
                   dev: str = Depends(current_dev)):
    r = store.get_submission(sub_id)
    if r is None or r["developer"] != dev:
        raise HTTPException(404)
    payload = json.loads(r["payload_json"] or "{}")
    return templates.TemplateResponse(request, "_dev_detail.html", {
        "s": dict(r),
        "audit": store.audit_submission(r["type"], payload),
        "pretty": json.dumps(payload, ensure_ascii=False, indent=2),
        "live": store.get_tool(r["name"]) is not None
        or r["name"] in store.installed_names("skills")
        or r["name"] in store.installed_names("subagents")
        or r["name"] in store.installed_names("mcp_servers"),
    })


@dev_router.post("/submit", response_class=HTMLResponse)
def dev_submit(request: Request, dev: str = Depends(current_dev),
               type: str = Form(...), name: str = Form(...),
               payload: str = Form(...)):
    try:
        data = json.loads(payload)
        data.setdefault("name", name)
    except Exception:  # noqa: BLE001
        return HTMLResponse('<div class="ok" style="background:var(--red-soft);'
                            'color:var(--red)">JSON ไม่ถูกต้อง</div>')
    store.add_submission(type, name, data, dev)
    mine = [s for s in store.list_submissions() if s["developer"] == dev]
    return templates.TemplateResponse(request, "_dev_list.html", {"mine": mine})


# ---- pages -----------------------------------------------------------------

def _counts() -> dict:
    with store.conn() as c:
        def n(q):
            return c.execute(q).fetchone()[0]
        return {
            "tools": n("SELECT COUNT(*) FROM tools"),
            "skills": n("SELECT COUNT(*) FROM skills"),
            "subagents": n("SELECT COUNT(*) FROM subagents"),
            "mcp": n("SELECT COUNT(*) FROM mcp_servers"),
            "backlog": n("SELECT COUNT(*) FROM capability_requests"
                         " WHERE status!='done'"),
            "version": (c.execute("SELECT MAX(version) FROM catalog_versions")
                        .fetchone()[0] or 0),
        }


@router.get("", response_class=HTMLResponse)
def dashboard(request: Request, admin: str = Depends(owner)):
    return templates.TemplateResponse(
        request, "dashboard.html", {"admin": admin, "counts": _counts()})


@router.get("/tab/tools", response_class=HTMLResponse)
def tab_tools(request: Request, admin: str = Depends(owner)):
    with store.conn() as c:
        rows = c.execute("SELECT * FROM tools ORDER BY kind,name").fetchall()
    return templates.TemplateResponse(request, "_tools.html", {"rows": rows})


@router.get("/tab/backlog", response_class=HTMLResponse)
def tab_backlog(request: Request, admin: str = Depends(owner)):
    rows = store.list_capability_requests()
    return templates.TemplateResponse(request, "_backlog.html", {"rows": rows})


@router.post("/capability/{req_id}/status/{status}", response_class=HTMLResponse)
def capability_status(req_id: int, status: str, request: Request,
                      admin: str = Depends(owner)):
    if status in ("requested", "building", "done"):
        store.set_capability_status(req_id, status)
    return tab_backlog(request, admin)


@router.post("/tools/{name}/toggle", response_class=HTMLResponse)
def toggle_tool(name: str, request: Request, admin: str = Depends(owner)):
    with store.conn() as c:
        c.execute("UPDATE tools SET enabled=1-enabled,updated_at=? WHERE name=?",
                  (time.time(), name))
        row = c.execute("SELECT * FROM tools WHERE name=?", (name,)).fetchone()
    return templates.TemplateResponse(request, "_tool_row.html", {"r": row})


# Registry-backed tabs: installed rows + the curated catalog still available.
_REG = {
    "mcp": ("mcp_servers", lambda: registry.MCP),
    "skills": ("skills", lambda: registry.SKILLS),
    "subagents": ("subagents", lambda: registry.SUBAGENTS),
}


@router.get("/tool/{name}/edit", response_class=HTMLResponse)
def tool_edit(name: str, request: Request, admin: str = Depends(owner)):
    r = store.get_tool(name)
    if r is None:
        raise HTTPException(404)
    pricing = json.loads(r["pricing_json"]) if r["pricing_json"] else {}
    return templates.TemplateResponse(
        request, "_tool_edit.html", {"r": r, "pricing": pricing})


@router.post("/tool/{name}", response_class=HTMLResponse)
def tool_save(name: str, request: Request, admin: str = Depends(owner),
              label: str = Form(""), blurb: str = Form(""),
              category: str = Form(""), provider: str = Form(""),
              tier: str = Form("free"), amount: str = Form(""),
              period: str = Form("month")):
    store.update_tool_meta(name, label, blurb, category, provider, tier,
                           amount, period)
    return tab_tools(request, admin)


def _render_registry(request: Request, tab: str):
    table, items = _REG[tab]
    installed = store.installed_names(table)
    with store.conn() as c:
        rows = [dict(r) for r in c.execute(
            f"SELECT * FROM {table} ORDER BY name").fetchall()]
    available = [it for it in items() if it["name"] not in installed]
    by_cat: dict[str, list] = {}
    for it in available:
        by_cat.setdefault(it.get("category", "อื่น ๆ"), []).append(it)
    return templates.TemplateResponse(
        request, f"_{tab}.html",
        {"tab": tab, "rows": rows, "avail": available, "by_cat": by_cat})


@router.get("/tab/mcp", response_class=HTMLResponse)
@router.get("/tab/skills", response_class=HTMLResponse)
@router.get("/tab/subagents", response_class=HTMLResponse)
def tab_registry(request: Request, admin: str = Depends(owner)):
    return _render_registry(request, request.url.path.rsplit("/", 1)[-1])


@router.post("/install/{tab}/{name}", response_class=HTMLResponse)
def install(tab: str, name: str, request: Request,
            admin: str = Depends(owner)):
    items = _REG[tab][1]()
    item = next((i for i in items if i["name"] == name), None)
    if item is None:
        raise HTTPException(404)
    {"mcp": store.install_mcp, "skills": store.install_skill,
     "subagents": store.install_subagent}[tab](item)
    return _render_registry(request, tab)


@router.post("/uninstall/{tab}/{name}", response_class=HTMLResponse)
def uninstall(tab: str, name: str, request: Request,
              admin: str = Depends(owner)):
    {"mcp": store.uninstall_mcp, "skills": store.uninstall_skill,
     "subagents": store.uninstall_subagent}[tab](name)
    return _render_registry(request, tab)


# ---- developer portal + review queue ---------------------------------------

def _review_rows() -> list[dict]:
    out = []
    for s in store.list_submissions("pending"):
        payload = json.loads(s["payload_json"] or "{}")
        out.append({**s, "audit": store.audit_submission(s["type"], payload)})
    return out


@router.get("/tab/review", response_class=HTMLResponse)
def tab_review(request: Request, admin: str = Depends(owner)):
    return templates.TemplateResponse(request, "_review.html",
                                      {"rows": _review_rows()})


@router.post("/review/{sub_id}/{action}", response_class=HTMLResponse)
def review_action(sub_id: int, action: str, request: Request,
                  admin: str = Depends(owner)):
    if action == "approve":
        store.approve_submission(sub_id)
    else:
        store.set_submission_status(sub_id, "rejected")
    return templates.TemplateResponse(request, "_review.html",
                                      {"rows": _review_rows()})


@router.get("/tab/{tab}", response_class=HTMLResponse)
def tab_generic(tab: str, request: Request, admin: str = Depends(owner)):
    q = {
        "catalog": "SELECT version,published_at,author FROM catalog_versions"
                   " ORDER BY version DESC LIMIT 20",
        "logs": "SELECT ts,tool,kind,arg_keys,status FROM tool_logs"
                " ORDER BY ts DESC LIMIT 50",
    }.get(tab)
    if q is None:
        raise HTTPException(404)
    with store.conn() as c:
        rows = [dict(r) for r in c.execute(q).fetchall()]
    return templates.TemplateResponse(
        request, "_simple.html", {"tab": tab, "rows": rows})


# ---- publish (Ed25519-signed snapshot) -------------------------------------

def _signing_key() -> Ed25519PrivateKey:
    """Load the catalog signing key (PEM in PIN_CATALOG_KEY) or a dev key."""
    from cryptography.hazmat.primitives import serialization
    pem = os.environ.get("PIN_CATALOG_KEY")
    if pem:
        return serialization.load_pem_private_key(pem.encode(), password=None)
    return Ed25519PrivateKey.generate()  # dev only — non-persistent


def build_signed_catalog() -> dict:
    from pin_proxy import catalog
    payload = {"tools": catalog.manifests()}
    blob = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    sig = base64.b64encode(_signing_key().sign(blob.encode())).decode()
    return {"payload": payload, "blob": blob, "sig": sig}


@router.post("/catalog/publish", response_class=HTMLResponse)
def publish(request: Request, admin: str = Depends(owner)):
    signed = build_signed_catalog()
    with store.conn() as c:
        cur = c.execute(
            "INSERT INTO catalog_versions(signed_blob,published_at,author,diff)"
            " VALUES(?,?,?,?)",
            (json.dumps({"blob": signed["blob"], "sig": signed["sig"]}),
             time.time(), admin, "published"))
        version = cur.lastrowid
    return HTMLResponse(
        f'<div class="ok">เผยแพร่ catalog v{version} แล้ว ✓</div>')
