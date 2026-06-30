"""Admin backoffice — HTMX + Jinja, server-rendered, owner-only. Manages the
catalog/skills/MCP/subagents config and publishes a signed catalog snapshot.

Auth uses tuwunel (Matrix): the admin logs in with their ปิ่น account; we
exchange username/password for a homeserver access token, keep it in an
httpOnly cookie, and validate it via `whoami` on each request. Owners (full
backoffice) are listed in PIN_ADMIN_OWNERS; everyone else is a developer.
Manages config only — never user content.
"""

from __future__ import annotations

import email as emaillib
import imaplib
import json
import os
import re
import smtplib
import time
from email.message import EmailMessage
from email.utils import make_msgid, parseaddr

import httpx
from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from pin_proxy import store

from . import emails

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
    """Owner-only routes; non-owners get a plain 403."""
    uid = _auth(request, "/admin/login")
    if not _is_owner(uid):
        raise HTTPException(status_code=403, detail="owners only")
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
    resp = RedirectResponse("/admin", status_code=303)
    resp.set_cookie(_COOKIE, token, httponly=True, samesite="lax",
                    max_age=8 * 3600)
    return resp


@router.post("/logout")
def logout():
    resp = RedirectResponse("/admin/login", status_code=303)
    resp.delete_cookie(_COOKIE)
    return resp


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
        }


@router.get("", response_class=HTMLResponse)
def dashboard(request: Request, admin: str = Depends(owner)):
    return templates.TemplateResponse(
        request, "dashboard.html", {"admin": admin, "counts": _counts()})


@router.get("/tab/backlog", response_class=HTMLResponse)
def tab_backlog(request: Request, admin: str = Depends(owner)):
    rows = store.list_capability_requests()
    return templates.TemplateResponse(request, "_backlog.html", {"rows": rows})


def _push_rows() -> list[dict]:
    import time as _t

    rows = store.list_push_devices()
    now = _t.time()
    for r in rows:
        age = now - (r.get("updated_at") or 0)
        r["ago"] = (
            "เมื่อกี้" if age < 3600
            else f"{int(age // 3600)} ชม.ก่อน" if age < 86400
            else f"{int(age // 86400)} วันก่อน"
        )
        r["device_short"] = (r.get("device") or "")[:16] + "…"
    return rows


@router.get("/tab/push", response_class=HTMLResponse)
def tab_push(request: Request, admin: str = Depends(owner)):
    return templates.TemplateResponse(
        request, "_push.html", {"rows": _push_rows()})


@router.post("/push/wake", response_class=HTMLResponse)
async def push_wake(request: Request, user_id: str = Form(...),
                    admin: str = Depends(owner)):
    """Force-wake a user's device — sends a blind FCM/APNs wake with force=1 so
    the on-device agent runs ALL its watchers/jobs NOW, ignoring the schedule.
    Ops/test trigger; no content travels (the prompt/result stay on the phone)."""
    from pin_proxy import scheduler

    dev = next((d for d in store.list_push_devices()
                if d["user_id"] == user_id), None)
    msg = "ไม่พบอุปกรณ์"
    if dev and dev.get("device"):
        try:
            await scheduler._push(
                dev["device"], "admin-wake", dev.get("platform", "apns"),
                force=True)
            msg = f"ปลุก {user_id} แล้ว ({dev.get('platform')})"
        except Exception as e:  # noqa: BLE001
            msg = f"ปลุกไม่สำเร็จ: {e}"
    return templates.TemplateResponse(
        request, "_push.html", {"rows": _push_rows(), "flash": msg})


@router.post("/capability/{req_id}/status/{status}", response_class=HTMLResponse)
def capability_status(req_id: int, status: str, request: Request,
                      admin: str = Depends(owner)):
    if status in ("requested", "building", "done"):
        store.set_capability_status(req_id, status)
    return tab_backlog(request, admin)


# Per-tool "params" editor, reached from the store card (like the MCP defaults
# editor). news_reporter's params = its RSS feeds per topic.
_NEWS_TOPICS = [("general", "ข่าวทั่วไป"), ("ai", "ข่าว AI")]


@router.get("/tool/{name}/config", response_class=HTMLResponse)
def tool_config(name: str, request: Request, admin: str = Depends(owner)):
    sources = store.get_tool_config(name).get("sources", {})
    topics = [(tid, lbl, sources.get(tid, [])) for tid, lbl in _NEWS_TOPICS]
    return templates.TemplateResponse(
        request, "_tool_config.html", {"name": name, "topics": topics})


@router.post("/tool/{name}/config", response_class=HTMLResponse)
async def tool_config_save(name: str, request: Request,
                           admin: str = Depends(owner)):
    f = await request.form()
    sources: dict[str, list] = {}
    for tid, _ in _NEWS_TOPICS:
        feeds = []
        for line in (f.get(tid) or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]  # url | name | slug
            feeds.append({"url": parts[0],
                          "name": parts[1] if len(parts) > 1 else "",
                          "slug": parts[2] if len(parts) > 2 else ""})
        sources[tid] = feeds
    store.set_tool_config(name, {"sources": sources})
    return tab_store(request, admin)


# ---- MCP tool default params (configure per param: fixed value or $user) -----
@router.get("/mcp/server/{server}/tools", response_class=HTMLResponse)
def mcp_server_tools(server: str, request: Request,
                     admin: str = Depends(owner)):
    return templates.TemplateResponse(request, "_mcp_tools.html",
        {"server": server, "tools": store.mcp_tools_for_server(server)})


@router.post("/mcp/server/{server}/refresh", response_class=HTMLResponse)
async def mcp_refresh(server: str, request: Request,
                      admin: str = Depends(owner)):
    from pin_proxy import mcp
    await mcp.refresh_server(server)
    return templates.TemplateResponse(request, "_mcp_tools.html",
        {"server": server, "tools": store.mcp_tools_for_server(server)})


@router.post("/mcp/tool/{name}/defaults", response_class=HTMLResponse)
async def mcp_set_defaults(name: str, request: Request,
                           admin: str = Depends(owner)):
    form = await request.form()
    # Each param input is named default__<param>; blank = not defaulted.
    defaults = {k[len("default__"):]: str(v).strip()
                for k, v in form.items()
                if k.startswith("default__") and str(v).strip()}
    store.set_mcp_defaults(name, defaults)
    return templates.TemplateResponse(request, "_mcp_tools.html",
        {"server": form.get("_server", ""),
         "tools": store.mcp_tools_for_server(form.get("_server", ""))})


# ---- ร้านค้า: the catalog as the app's capability store (the one mgmt surface) -
@router.get("/tab/store", response_class=HTMLResponse)
def tab_store(request: Request, admin: str = Depends(owner)):
    by_cat: dict[str, list] = {}
    providers: set[str] = set()
    commercial: set[str] = set()  # providers with a paid capability
    comm_cats: set[str] = set()  # categories with a paid capability
    for m in store.all_capabilities():  # enabled + disabled
        cat = m.get("category") or "อื่น ๆ"
        by_cat.setdefault(cat, []).append(m)
        paid = (m.get("pricing") or {}).get("tier", "free") != "free"
        if paid:
            comm_cats.add(cat)
        if m.get("provider"):
            providers.add(m["provider"])
            if paid:
                commercial.add(m["provider"])
    return templates.TemplateResponse(
        request, "_store.html",
        {"by_cat": by_cat,
         "providers": sorted(providers), "commercial": sorted(commercial),
         "categories": sorted(by_cat.keys()), "comm_cats": sorted(comm_cats)})


@router.post("/store/{name}", response_class=HTMLResponse)
async def store_save(name: str, request: Request, admin: str = Depends(owner)):
    f = await request.form()
    store.set_store_meta(name, category=f.get("category"), status=f.get("status"),
                         tier=f.get("tier"), amount=f.get("amount"),
                         period=f.get("period", "month"), render=f.get("render"),
                         ask_params=f.get("ask_params"))
    return tab_store(request, admin)


@router.post("/store/{name}/toggle", response_class=HTMLResponse)
def store_toggle(name: str, request: Request, admin: str = Depends(owner)):
    store.toggle_capability(name)
    return tab_store(request, admin)


# ---- waitlist outreach (SMTP early-access mail, personalised per use-case) ---

def _gmail_creds() -> tuple[str, str, str]:
    """(login_user, app_password, from_header) — Gmail Workspace.
    Login is the real account (chatchai@); From is the pin@ send-as alias."""
    user = os.environ.get("GMAIL_USER", "chatchai@tokens2.io")
    pw = (os.environ.get("GG_APP_PASSWORD_PIN")
          or os.environ.get("GMAIL_APP_PASSWORD", "")).replace(" ", "")
    sender = os.environ.get("GMAIL_FROM", "ปิ่น <pin@tokens2.io>")
    return user, pw, sender


def _send_email(to: str, subject: str, text: str, html: str) -> str:
    """Send via Gmail Workspace SMTP (send-as pin@). Returns the Message-ID so
    the outbound row can be threaded against captured replies."""
    user, pw, sender = _gmail_creds()
    msg_id = make_msgid(domain="tokens2.io")
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to
    msg["Reply-To"] = sender
    msg["Message-ID"] = msg_id
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as s:
        s.starttls()
        s.login(user, pw)
        s.send_message(msg)
    return msg_id


_UNSUB_WORDS = ("unsubscribe", "เลิกรับ", "ยกเลิกรับ", "ไม่รับ", "เลิกติดตาม",
                "opt out", "opt-out")


def _is_unsubscribe(body: str) -> bool:
    low = (body or "").lower()
    return any(w in low for w in _UNSUB_WORDS)


def _extract_text(m) -> str:
    """Best-effort plain-text body from a parsed email, quoted history trimmed."""
    body = ""
    parts = m.walk() if m.is_multipart() else [m]
    for part in parts:
        if part.get_content_type() == "text/plain" and \
                "attachment" not in str(part.get("Content-Disposition", "")):
            try:
                body = part.get_content()
            except Exception:  # noqa: BLE001
                body = (part.get_payload(decode=True) or b"").decode(
                    part.get_content_charset() or "utf-8", "replace")
            break
    # cut quoted reply ("On ... wrote:" or leading "> " blocks)
    body = re.split(r"\n\s*On .*wrote:\s*\n|\n\s*>", body, maxsplit=1)[0]
    return body.strip()


def _poll_mail() -> int:
    """Poll the Gmail inbox (login account) for replies, match each to a
    waitlist person (by sender or In-Reply-To), store inbound rows. Read-only:
    leaves unmatched mail untouched."""
    user, pw, _ = _gmail_creds()
    wl = store.waitlist_email_set()
    out_idx = store.mail_out_index()
    added = 0
    M = imaplib.IMAP4_SSL("imap.gmail.com", 993)
    try:
        M.login(user, pw)
        M.select("INBOX")
        _typ, data = M.search(None, "UNSEEN")
        for num in (data[0] or b"").split():
            _typ, md = M.fetch(num, "(RFC822)")
            if not md or not md[0]:
                continue
            m = emaillib.message_from_bytes(md[0][1])
            frm = parseaddr(m.get("From", ""))[1].lower()
            msgid = (m.get("Message-ID") or "").strip()
            irt = (m.get("In-Reply-To") or "").strip()
            who = frm if frm in wl else out_idx.get(irt)
            if not who:
                continue  # not a waitlist reply — leave it UNSEEN
            if not store.mail_msgid_seen(msgid):
                body = _extract_text(m)
                store.add_mail_message(who, "in", m.get("Subject", ""),
                                       body, msgid, irt)
                if _is_unsubscribe(body):
                    store.mark_waitlist_unsubscribed(who)
                added += 1
            M.store(num, "+FLAGS", "\\Seen")
    finally:
        try:
            M.logout()
        except Exception:  # noqa: BLE001
            pass
    return added


_PERSONA_TH = {"study": "ติว/ทบทวน", "home": "เรื่องในบ้าน", "creative": "ครีเอทีฟ",
               "sme": "ร้านค้า", "work": "จัดการงาน", "default": "ทั่วไป"}


def _wl_render(request: Request, flash: str = ""):
    import time as _t
    rows = store.list_waitlist()
    replies = store.mail_reply_counts()
    for r in rows:
        r["persona_th"] = _PERSONA_TH.get(emails.classify(r.get("use") or ""), "")
        sa = r.get("sent_at")
        r["sent"] = bool(sa)
        r["sent_th"] = _t.strftime("%d/%m %H:%M", _t.localtime(sa)) if sa else ""
        r["replies"] = replies.get(r["email"], 0)
        r["unsub"] = bool(r.get("unsubscribed_at"))
    return templates.TemplateResponse(request, "_waitlist.html", {
        "rows": rows, "flash": flash,
        "unsent": sum(1 for r in rows if not r["sent"] and not r["unsub"])})


@router.get("/tab/waitlist", response_class=HTMLResponse)
def tab_waitlist(request: Request, admin: str = Depends(owner)):
    return _wl_render(request)


@router.post("/waitlist/poll", response_class=HTMLResponse)
def waitlist_poll(request: Request, admin: str = Depends(owner)):
    try:
        n = _poll_mail()
        flash = f"ดึงเมลแล้ว · reply ใหม่ {n}" if n else "ดึงเมลแล้ว · ไม่มี reply ใหม่"
    except Exception as e:  # noqa: BLE001
        flash = f"ดึงเมลไม่สำเร็จ: {e}"
    return _wl_render(request, flash)


@router.get("/waitlist/{wid}/thread", response_class=HTMLResponse)
def waitlist_thread(wid: int, request: Request, admin: str = Depends(owner)):
    import time as _t
    row = next((r for r in store.list_waitlist() if r["id"] == wid), None)
    if row is None:
        raise HTTPException(404)
    msgs = store.mail_thread(row["email"])
    for m in msgs:
        m["ts_th"] = _t.strftime("%d/%m %H:%M", _t.localtime(m.get("created_at") or 0))
    return templates.TemplateResponse(request, "_waitlist_thread.html",
                                      {"to": row["email"], "msgs": msgs})


@router.get("/waitlist/{wid}/preview", response_class=HTMLResponse)
def waitlist_preview(wid: int, request: Request, admin: str = Depends(owner)):
    row = next((r for r in store.list_waitlist() if r["id"] == wid), None)
    if row is None:
        raise HTTPException(404)
    subject, _text, html = emails.build(row.get("use") or "")
    return templates.TemplateResponse(request, "_waitlist_preview.html", {
        "to": row["email"], "subject": subject, "html": html, "wid": wid,
        "sent": bool(row.get("sent_at"))})


@router.post("/waitlist/{wid}/send", response_class=HTMLResponse)
def waitlist_send(wid: int, request: Request, admin: str = Depends(owner)):
    row = next((r for r in store.list_waitlist() if r["id"] == wid), None)
    if row is None:
        raise HTTPException(404)
    if row.get("unsubscribed_at"):
        return _wl_render(request, f"{row['email']} ยกเลิกรับแล้ว — ไม่ส่ง")
    subject, text, html = emails.build(row.get("use") or "")
    try:
        mid = _send_email(row["email"], subject, text, html)
        store.mark_waitlist_sent(row["email"])
        store.add_mail_message(row["email"], "out", subject, text, mid)
        flash = f"ส่งหา {row['email']} แล้ว ✓"
    except Exception as e:  # noqa: BLE001
        flash = f"ส่งไม่สำเร็จ ({row['email']}): {e}"
    return _wl_render(request, flash)


@router.post("/waitlist/send-unsent", response_class=HTMLResponse)
def waitlist_send_unsent(request: Request, admin: str = Depends(owner)):
    sent, fail = 0, 0
    for row in store.list_waitlist():
        if row.get("sent_at") or row.get("unsubscribed_at"):
            continue
        subject, text, html = emails.build(row.get("use") or "")
        try:
            mid = _send_email(row["email"], subject, text, html)
            store.mark_waitlist_sent(row["email"])
            store.add_mail_message(row["email"], "out", subject, text, mid)
            sent += 1
        except Exception:  # noqa: BLE001
            fail += 1
    return _wl_render(request, f"ส่งสำเร็จ {sent} · ล้มเหลว {fail}")


@router.get("/tab/{tab}", response_class=HTMLResponse)
def tab_generic(tab: str, request: Request, admin: str = Depends(owner)):
    q = {
        "logs": "SELECT ts,tool,kind,arg_keys,status FROM tool_logs"
                " ORDER BY ts DESC LIMIT 50",
    }.get(tab)
    if q is None:
        raise HTTPException(404)
    with store.conn() as c:
        rows = [dict(r) for r in c.execute(q).fetchall()]
    return templates.TemplateResponse(
        request, "_simple.html", {"tab": tab, "rows": rows})
