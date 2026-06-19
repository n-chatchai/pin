"""news-reporter — sample EXTERNAL developer remote subagent.

NOT platform code. A developer hosts this on their own server; ปิ่น's proxy
routes blind calls here. It fetches an RSS feed and returns a ready flex card of
items newer than `since`, plus the new cursor. No new → {skip}.

Run:  uv run uvicorn main:app --host 0.0.0.0 --port 8090
"""

from __future__ import annotations

import os
import re
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

import httpx
from fastapi import FastAPI, Request

app = FastAPI(title="news-reporter (dev sample)")

# The DEVELOPER's own LLM key (not the platform's) — they pay for summarisation.
_GKEY = os.environ.get("GEMINI_API_KEY", "")
_GEMINI = ("https://generativelanguage.googleapis.com/v1beta/models/"
           "gemini-flash-lite-latest:generateContent")


async def _digest(client: httpx.AsyncClient, title: str, text: str,
                  lang: str = "Thai") -> dict:
    """One LLM call → translated headline + a complete short summary, in the
    user's language (default Thai). Summary stays whole (no truncation)."""
    if not _GKEY or not text:
        return {}
    prompt = (
        f"You are a news editor. Output in {lang}. Translate the headline to a "
        f"short, natural {lang} headline, and write a self-contained summary of "
        "1-2 short complete sentences (do NOT cut mid-sentence, no preamble). "
        'Reply ONLY as JSON: {"title": "...", "summary": "..."}\n\n'
        f"Headline: {title}\n\nBody: {text[:4000]}")
    try:
        r = await client.post(
            _GEMINI, params={"key": _GKEY},
            json={"contents": [{"parts": [{"text": prompt}]}],
                  "generationConfig": {"responseMimeType": "application/json"}})
        parts = r.json()["candidates"][0]["content"]["parts"]
        raw = "".join(p.get("text", "") for p in parts).strip()
        import json as _json
        d = _json.loads(raw)
        return {"title": (d.get("title") or "").strip(),
                "summary": (d.get("summary") or "").strip()}
    except Exception:  # noqa: BLE001
        return {}

_IMG = re.compile(r'<img[^>]+src="([^"]+)"', re.I)
_TAG = re.compile(r"<[^>]+>")
_OG = re.compile(
    r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)', re.I)
_CONTENT = "{http://purl.org/rss/1.0/modules/content/}encoded"


def _items(xml: str) -> list[dict]:
    """RSS 2.0 → newest-first [{title,link,date,guid,summary,image}]."""
    out: list[dict] = []
    try:
        root = ET.fromstring(xml)
    except Exception:  # noqa: BLE001
        return out
    for it in root.iter("item"):
        def g(tag: str) -> str:
            e = it.find(tag)
            return (e.text or "").strip() if e is not None and e.text else ""
        desc = g("description") or g(_CONTENT)
        m = _IMG.search(desc)
        enc = it.find("enclosure")
        img = (m.group(1) if m else "") or (
            enc.get("url", "") if enc is not None
            and "image" in (enc.get("type", "")) else "")
        text = re.sub(r"\s+", " ", _TAG.sub(" ", desc)).strip()
        out.append({
            "title": g("title"), "link": g("link"), "date": g("pubDate"),
            "guid": g("guid") or g("link"), "summary": text[:240],
            "content": text, "image": img,
            "pub": g("source"),  # Google News carries the real publisher here
        })
    return out


async def _og_image(client: httpx.AsyncClient, url: str) -> str:
    """Cover image from the post's og:image meta (when the feed has none)."""
    try:
        r = await client.get(url, headers={"User-Agent": "news-reporter/1"})
        m = _OG.search(r.text)
        return m.group(1) if m else ""
    except Exception:  # noqa: BLE001
        return ""


# Sources per topic (developer's choice). `slug` (optional) filters one feed.
_AI_SOURCES = [
    {"name": "Latent Space", "url": "https://www.latent.space/feed",
     "slug": "ainews"},
    {"name": "TechCrunch AI",
     "url": "https://techcrunch.com/category/artificial-intelligence/feed/"},
    {"name": "Hugging Face", "url": "https://huggingface.co/blog/feed.xml"},
]
# Default = general headlines (Thai). Google News carries a per-item publisher.
_GENERAL_SOURCES = [
    {"name": "Google News",
     "url": "https://news.google.com/rss?hl=th&gl=TH&ceid=TH:th"},
    {"name": "BBC ไทย", "url": "https://feeds.bbci.co.uk/thai/rss.xml"},
]

_AI_HINTS = ("ai", "เอไอ", "ปัญญาประดิษฐ์", "artificial", "machine learning")


def _sources_for(topic: str) -> list[dict]:
    """Pick the source set from a free-text topic. Empty/unknown → general."""
    t = topic.lower()
    return _AI_SOURCES if any(k in t for k in _AI_HINTS) else _GENERAL_SOURCES


def _norm(title: str) -> str:
    return re.sub(r"[^a-z0-9ก-๙]+", "", title.lower())[:60]


@app.post("/run")
async def run(request: Request) -> dict:
    b = await request.json()
    seen_cursor = (b.get("since") or "").strip()  # last guid already shown
    lang = (b.get("lang") or "Thai").strip()  # user-setting language
    topic = (b.get("topic") or "").strip()  # "" = general, "ai" = AI feed
    sources = _sources_for(topic)

    # 1) pull every source in parallel-ish, tag with source name + filter slug.
    all_items: list[dict] = []
    async with httpx.AsyncClient(timeout=20, follow_redirects=True) as c:
        for src in sources:
            try:
                r = await c.get(src["url"],
                                headers={"User-Agent": "news-reporter/1"})
                for it in _items(r.text):
                    if src.get("slug") and src["slug"] not in it["link"].lower():
                        continue
                    it["source"] = it.get("pub") or src["name"]
                    all_items.append(it)
            except Exception:  # noqa: BLE001
                continue
    if not all_items:
        return {"text": "ดึงข่าวไม่ได้ตอนนี้"}

    # 2) sort newest-first, then dedupe by normalised title (cross-source).
    def _ts(it):
        try:
            return parsedate_to_datetime(it["date"]).timestamp()
        except Exception:  # noqa: BLE001
            return 0.0
    all_items.sort(key=_ts, reverse=True)
    deduped, seen = [], set()
    for it in all_items:
        k = _norm(it["title"])
        if k and k not in seen:
            seen.add(k)
            deduped.append(it)

    cursor = deduped[0]["guid"]
    # 3) only items newer than the cursor (skip already-shown).
    fresh = []
    for it in deduped:
        if seen_cursor and it["guid"] == seen_cursor:
            break
        fresh.append(it)
    fresh = fresh[:6] if seen_cursor else deduped[:6]
    if not fresh:
        return {"skip": True, "cursor": cursor}

    # 4) translate headline + summarise each (dev's own LLM), in the user's
    #    language → 5) one card per item = carousel.
    # Force IPv4 — this VPS's IPv6 is geo-blocked by the Gemini API.
    async with httpx.AsyncClient(
        timeout=30, follow_redirects=True,
        transport=httpx.AsyncHTTPTransport(local_address="0.0.0.0")) as c:
        for it in fresh:
            d = await _digest(c, it["title"], it["content"], lang)
            if d.get("title"):
                it["title"] = d["title"]
            if d.get("summary"):
                it["summary"] = d["summary"]  # whole — not truncated
    cards = [{
        "header": {"title": it["title"]},
        "body": [{"type": "text", "text": it["summary"]}],
        # source + tap-to-open pinned in the footer → aligned across cards.
        "footer": {"icon": "news", "text": it["source"],
                   "trailing": "อ่านต่อ →", "action": {"data": it["link"]}},
    } for it in fresh]
    return {"flex": {"carousel": cards}, "cursor": cursor}
