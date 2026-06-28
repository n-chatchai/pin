"""ปิ่น LLM proxy — blind, stateless router.

The on-device Dart brain assembles the prompt (with on-device context) and
POSTs an OpenAI-style chat-completions payload here. We route it to a provider
and stream the response straight back. We hold the provider key (so it's never
in the app) but we do NOT store or log prompt/response content.

- FREE tier  → Google Gemini (OpenAI-compatible endpoint), our key.
- PAID tier  → OpenRouter, the customer's key (header), so we stay blind.

Both speak the same OpenAI chat-completions schema → this stays a thin router.
"""

from __future__ import annotations

import asyncio
import base64
import os
import re
import time

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, File, Header, HTTPException, Request, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware

load_dotenv()

GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/openai"
GEMINI_NATIVE = "https://generativelanguage.googleapis.com/v1beta"
GEMINI_OPENAI = f"{GEMINI_BASE}/chat/completions"
GEMINI_EMBED = f"{GEMINI_BASE}/embeddings"
OPENROUTER = "https://openrouter.ai/api/v1/chat/completions"
FREE_MODEL = os.environ.get("PIN_FREE_MODEL", "gemini-flash-lite-latest")
EMBED_MODEL = os.environ.get("PIN_EMBED_MODEL", "gemini-embedding-001")
EMBED_DIM = int(os.environ.get("PIN_EMBED_DIM", "256"))

# This VPS's IPv6 maps to a region Gemini geo-blocks ("User location is not
# supported"), while its IPv4 is fine. Bind to 0.0.0.0 → force IPv4 for the
# Gemini calls. (No root needed; per-process.)
_IPV4 = httpx.AsyncHTTPTransport(local_address="0.0.0.0")

app = FastAPI(title="pin-proxy")

# Browser requests only come from the marketing site (public /waitlist). The
# app's authed endpoints are called natively (no Origin header, CORS n/a).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://pin.tokens2.io"],
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_methods=["POST"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def _startup() -> None:
    # The admin backoffice now lives in the separate `pin-admin` app; it shares
    # this store (the admin-editable catalog/skills/MCP source of truth).
    from . import scheduler, store

    store.init()
    asyncio.create_task(scheduler.poller())


# Per-user auth: the caller's Matrix access token, validated against the
# homeserver `whoami`. Validated results are cached (token → user_id) so we hit
# the homeserver at most once per token per TTL window, not on every request.
_HOMESERVER = os.environ.get(
    "PIN_HOMESERVER", "http://127.0.0.1:6167"
).rstrip("/")
_WHOAMI_TTL = float(os.environ.get("PIN_WHOAMI_TTL", "300"))
_whoami_cache: dict[str, tuple[str, float]] = {}


def _check_token(authorization: str | None) -> str:
    """Validate the caller's Matrix access token via the homeserver `whoami`
    and return their user_id. Raises 401 if the token is missing/invalid, 503
    if the homeserver can't be reached."""
    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="unauthorized")
    now = time.monotonic()
    hit = _whoami_cache.get(token)
    if hit and hit[1] > now:
        return hit[0]
    try:
        r = httpx.get(
            f"{_HOMESERVER}/_matrix/client/v3/account/whoami",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5.0,
        )
    except Exception:
        raise HTTPException(status_code=503, detail="auth backend unreachable")
    if r.status_code != 200:
        _whoami_cache.pop(token, None)
        raise HTTPException(status_code=401, detail="unauthorized")
    user_id = r.json().get("user_id", "")
    _whoami_cache[token] = (user_id, now + _WHOAMI_TTL)
    return user_id


@app.get("/health")
def health() -> dict:
    return {"ok": True}


_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_WL_HITS: dict[str, list[float]] = {}  # ip -> recent submit times (rate limit)


@app.post("/waitlist")
async def waitlist(request: Request) -> dict:
    """Public pre-launch signup from the marketing site. No auth — guarded by a
    honeypot + a per-IP rate limit (dedupe by email is in store.add_waitlist).
    Stores {email, use} only — no conversation content."""
    from . import store

    b = await request.json()
    # Honeypot: humans leave 'hp' empty, bots auto-fill every field. Silently
    # accept (don't tip the bot off) but store nothing.
    if str(b.get("hp", "")).strip():
        return {"ok": True}
    # Per-IP rate limit: 5/hour. ponytail: in-process dict, fine for a single
    # instance — move to redis if this ever runs multi-worker.
    ip = (request.headers.get("cf-connecting-ip")
          or request.headers.get("x-forwarded-for", "").split(",")[0].strip()
          or (request.client.host if request.client else "?"))
    now = time.time()
    hits = [t for t in _WL_HITS.get(ip, []) if now - t < 3600]
    if len(hits) >= 5:
        raise HTTPException(status_code=429, detail="too many requests")
    hits.append(now)
    _WL_HITS[ip] = hits
    email = str(b.get("email", "")).strip()
    if not _EMAIL_RE.match(email):
        raise HTTPException(status_code=422, detail="invalid email")
    store.add_waitlist(email, str(b.get("use", ""))[:200])
    return {"ok": True}


@app.post("/schedule/register")
async def schedule_register(
    request: Request, authorization: str | None = Header(default=None)
) -> dict:
    """Register a wake — metadata only: {job_id, device, next_due(epoch), repeat}.
    No content: the prompt stays on the phone."""
    _check_token(authorization)
    from . import scheduler

    b = await request.json()
    scheduler.register(
        b["job_id"], b["device"], float(b["next_due"]),
        b.get("repeat", "once"),
    )
    return {"ok": True}


@app.post("/schedule/cancel")
async def schedule_cancel(
    request: Request, authorization: str | None = Header(default=None)
) -> dict:
    _check_token(authorization)
    from . import scheduler

    b = await request.json()
    return {"ok": scheduler.cancel(b["job_id"])}


@app.post("/capability")
async def capability_request(
    request: Request, authorization: str | None = Header(default=None)
) -> dict:
    """A user asked ปิ่น for something it can't do yet. Log the capability so it
    surfaces on the admin backlog. Body: {capability, detail?}. No conversation
    content — just the requested capability + the requesting user_id."""
    user = _check_token(authorization)
    from . import store

    b = await request.json()
    store.add_capability_request(
        str(b.get("capability", "")), str(b.get("detail", "")), user)
    return {"ok": True}


_MARKITDOWN = os.environ.get("PIN_MARKITDOWN_URL", "http://127.0.0.1:8093")


@app.post("/convert")
async def convert(
    file: UploadFile = File(...),
    authorization: str | None = Header(default=None),
) -> dict:
    """Forward an uploaded file to the markitdown service → Markdown text. The
    device extracts a summary on the model side; we don't store the file."""
    _check_token(authorization)
    data = await file.read()
    try:
        async with httpx.AsyncClient(timeout=120) as c:
            r = await c.post(
                f"{_MARKITDOWN}/convert",
                files={"file": (file.filename or "file", data,
                                file.content_type or "application/octet-stream")},
            )
        return r.json()
    except Exception as e:  # noqa: BLE001
        return {"markdown": "", "error": f"แปลงไฟล์ไม่ได้: {e}"}


def _audio_mime(name: str | None, ct: str | None) -> str:
    ext = (name or "").lower().rsplit(".", 1)[-1]
    return {
        "m4a": "audio/mp4", "mp4": "audio/mp4", "aac": "audio/aac",
        "wav": "audio/wav", "mp3": "audio/mpeg", "ogg": "audio/ogg",
        "flac": "audio/flac",
    }.get(ext, ct or "audio/mp4")


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    authorization: str | None = Header(default=None),
) -> dict:
    """Voice → text with Gemini's native multimodal audio (blind, IPv4). Better
    Thai than the free Google Web Speech path; one provider for chat/image/audio."""
    _check_token(authorization)
    gkey = os.environ.get("GEMINI_API_KEY")
    if not gkey:
        raise HTTPException(status_code=503, detail="proxy not configured")
    data = await file.read()
    payload = {
        "contents": [{
            "parts": [
                {"text": "ถอดเสียงพูดต่อไปนี้เป็นข้อความ ตอบเฉพาะข้อความที่ได้ยิน "
                         "ตามภาษาที่พูด ไม่ต้องอธิบายหรือเกริ่นนำ"},
                {"inline_data": {
                    "mime_type": _audio_mime(file.filename, file.content_type),
                    "data": base64.b64encode(data).decode(),
                }},
            ],
        }],
    }
    url = f"{GEMINI_NATIVE}/models/{FREE_MODEL}:generateContent"
    try:
        async with httpx.AsyncClient(timeout=60, transport=_IPV4) as c:
            r = await c.post(url, params={"key": gkey}, json=payload)
        parts = r.json()["candidates"][0]["content"]["parts"]
        text = "".join(p.get("text", "") for p in parts).strip()
        # Gemini sometimes prefixes a heading/label ("### Audio Transcript:")
        # despite the instruction — strip leading heading/label lines.
        lines = text.splitlines()
        while lines and (lines[0].lstrip().startswith("#")
                         or "transcript" in lines[0].lower()):
            lines.pop(0)
        return {"text": "\n".join(lines).strip() or text}
    except Exception as e:  # noqa: BLE001
        return {"text": "", "error": f"ถอดเสียงไม่ได้: {e}"}


@app.post("/debug/log")
async def debug_log(
    request: Request, authorization: str | None = Header(default=None)
) -> dict:
    """Debug-bot sink. The app posts a conversation turn here ONLY when the user
    enabled the 'ดีบักบอท' opt-in — it overrides the otherwise-blind model so the
    developer can review chats and improve ปิ่น. Appended as JSONL to a file."""
    _check_token(authorization)
    import json
    import time as _t

    body = await request.json()
    body["ts"] = _t.time()
    path = os.environ.get("PIN_DEBUG_LOG", os.path.expanduser("~/pin-debug.log"))
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(body, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001
        pass
    return {"ok": True}


@app.get("/catalog")
def catalog(authorization: str | None = Header(default=None)) -> dict:
    """Blind tool manifest the device fetches at runtime (hosted + MCP). No user
    content — cacheable/signable. {version, tools:[{name,kind,parameters,argKeys}]}."""
    _check_token(authorization)
    from . import catalog as cat

    tools = cat.manifests()
    return {"version": os.environ.get("PIN_CATALOG_VERSION", "1"), "tools": tools}


@app.get("/catalog/categories")
def catalog_categories(authorization: str | None = Header(default=None)) -> dict:
    """Categories of PAID capabilities (for the store's filter chips). Derived
    from the live catalog so admin edits flow through. {categories:[{id,label,
    count}]} — ordered by count desc."""
    _check_token(authorization)
    from . import catalog as cat

    counts: dict[str, int] = {}
    for m in cat.manifests():
        if (m.get("pricing") or {}).get("tier", "free") == "free":
            continue
        counts[m.get("category") or "อื่น ๆ"] = (
            counts.get(m.get("category") or "อื่น ๆ", 0) + 1)
    ordered = sorted(counts.items(), key=lambda kv: -kv[1])
    return {"categories": [{"id": k, "label": k, "count": v} for k, v in ordered]}


@app.post("/tool/{name}")
async def tool(
    name: str,
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict:
    """Run a blind, minimal-arg remote tool. args MUST contain no identity /
    conversation / preferences — only the narrow query. Routes MCP-fronted tools
    to the MCP layer, everything else to the hosted tools."""
    user = _check_token(authorization)
    from . import mcp
    from .tools import TOOLS

    args = await request.json()
    from . import store

    if mcp.is_mcp(name):
        store.log_tool(name, "mcp", list(args.keys()), "call")
        return await mcp.call(name, args, user)
    # Third-party tool hosted by a developer — route the blind args to their URL.
    endpoint = store.remote_endpoint(name)
    if endpoint:
        store.log_tool(name, "remote", list(args.keys()), "call")
        try:
            async with httpx.AsyncClient(timeout=30) as c:
                r = await c.post(endpoint, json=args)
            return r.json()
        except Exception as e:  # noqa: BLE001
            return {"text": f"เครื่องมือภายนอกมีปัญหา: {e}"}
    fn = TOOLS.get(name)
    if fn is None:
        store.log_tool(name, "?", list(args.keys()), "404")
        raise HTTPException(status_code=404, detail=f"no tool '{name}'")
    store.log_tool(name, "remote", list(args.keys()), "call")
    # Each tool returns {"text": ...} (fed back to the model) or {"flex": spec}.
    return await fn(args)


@app.post("/infer")
async def infer(
    request: Request,
    authorization: str | None = Header(default=None),
    x_pin_tier: str = Header(default="free"),
    x_openrouter_key: str | None = Header(default=None),
    x_openrouter_referer: str | None = Header(default=None),
) -> Response:
    _check_token(authorization)
    body = await request.json()  # OpenAI chat-completions payload (not stored)

    if x_pin_tier == "paid":
        if not x_openrouter_key:
            raise HTTPException(status_code=400, detail="missing OpenRouter key")
        url = OPENROUTER
        headers = {"Authorization": f"Bearer {x_openrouter_key}"}
        if x_openrouter_referer:
            headers["HTTP-Referer"] = x_openrouter_referer
        payload = body  # client picks the model
    else:  # free → our Gemini key
        gkey = os.environ.get("GEMINI_API_KEY")
        if not gkey:
            raise HTTPException(status_code=503, detail="proxy not configured")
        url = GEMINI_OPENAI
        headers = {"Authorization": f"Bearer {gkey}"}
        payload = {**body, "model": body.get("model") or FREE_MODEL}

    async with httpx.AsyncClient(timeout=90, transport=_IPV4) as c:
        r = await c.post(url, json=payload, headers=headers)
    # Passthrough — no logging of content.
    return Response(
        content=r.content,
        status_code=r.status_code,
        media_type=r.headers.get("content-type", "application/json"),
    )


@app.post("/embed")
async def embed(
    request: Request,
    authorization: str | None = Header(default=None),
) -> Response:
    """Embeddings for on-device semantic memory. Free tier only for now (our
    Gemini key); the body is OpenAI embeddings shape {input, [model]}."""
    _check_token(authorization)
    body = await request.json()
    gkey = os.environ.get("GEMINI_API_KEY")
    if not gkey:
        raise HTTPException(status_code=503, detail="proxy not configured")
    payload = {
        "model": body.get("model") or EMBED_MODEL,
        "input": body.get("input", ""),
        "dimensions": body.get("dimensions") or EMBED_DIM,
    }
    async with httpx.AsyncClient(timeout=30, transport=_IPV4) as c:
        r = await c.post(
            GEMINI_EMBED, json=payload,
            headers={"Authorization": f"Bearer {gkey}"},
        )
    return Response(
        content=r.content,
        status_code=r.status_code,
        media_type=r.headers.get("content-type", "application/json"),
    )


def run() -> None:
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("PIN_PROXY_HOST", "0.0.0.0"),
        port=int(os.environ.get("PIN_PROXY_PORT", "8088")),
        log_level="warning",  # avoid logging request bodies
    )


if __name__ == "__main__":
    run()
