"""Remote tool APIs — blind, minimal-arg. The on-device brain calls these with
ONLY the narrow query (place / base+quote / search text); never identity,
conversation, or preferences. We host them so the heavy/keyed bits (Gemini
grounding) stay server-side, but they hold no user context.
"""

from __future__ import annotations

import os
import urllib.parse

import httpx

# This VPS's IPv6 is geo-blocked by Gemini → force IPv4 for Gemini calls.
_IPV4 = httpx.AsyncHTTPTransport(local_address="0.0.0.0")

_GEO = "https://geocoding-api.open-meteo.com/v1/search"
_FORECAST = "https://api.open-meteo.com/v1/forecast"
_FX = "https://api.frankfurter.dev/v1/latest"
_GEMINI = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    "{model}:generateContent"
)


_DAY = ["วันนี้", "พรุ่งนี้"]


async def weather(args: dict) -> dict:
    place = (args.get("place") or "กรุงเทพ").strip()
    days = max(1, min(7, int(args.get("days") or 1)))
    async with httpx.AsyncClient(timeout=15) as c:
        g = await c.get(_GEO, params={"name": place, "count": 1, "language": "th"})
        hits = (g.json() or {}).get("results") or []
        if not hits:
            return {"text": f"หาเมือง “{place}” ไม่เจอ"}
        lat, lon = hits[0]["latitude"], hits[0]["longitude"]
        name = hits[0].get("name", place)
        f = await c.get(_FORECAST, params={
            "latitude": lat, "longitude": lon, "timezone": "Asia/Bangkok",
            "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max",
            "forecast_days": days,
        })
    d = (f.json() or {}).get("daily") or {}
    dates = d.get("time", [])
    cards = []
    for i in range(len(dates)):
        label = _DAY[i] if i < len(_DAY) else dates[i][5:].replace("-", "/")
        cards.append({
            "header": {"icon": "fx", "title": f"{name} · {label}"},
            "body": [
                {"type": "bignum",
                 "value": f"{d['temperature_2m_max'][i]:.0f}°",
                 "sub": f"ต่ำสุด {d['temperature_2m_min'][i]:.0f}°"},
                {"type": "text",
                 "text": f"โอกาสฝน {d['precipitation_probability_max'][i]}%"},
            ],
        })
    if not cards:
        return {"text": f"ดึงอากาศ {name} ไม่ได้"}
    return {"flex": cards[0] if len(cards) == 1 else {"carousel": cards}}


async def currency(args: dict) -> dict:
    base = (args.get("base") or "USD").upper()
    quote = (args.get("quote") or "THB").upper()
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(_FX, params={"base": base, "symbols": quote})
    rates = (r.json() or {}).get("rates") or {}
    if quote not in rates:
        return {"text": f"ดึงค่าเงิน {base}/{quote} ไม่ได้"}
    return {"flex": {
        "header": {"icon": "money", "title": f"{base} → {quote}"},
        "body": [
            {"type": "bignum", "value": f"{rates[quote]:.4f}",
             "sub": f"1 {base} = {rates[quote]:.4f} {quote}"},
        ],
    }}


async def web_search(args: dict) -> dict:
    query = (args.get("query") or "").strip()
    if not query:
        return {"text": "ไม่มีคำค้น"}
    gkey = os.environ.get("GEMINI_API_KEY")
    if not gkey:
        return {"text": "ค้นไม่ได้ตอนนี้"}
    model = os.environ.get("PIN_FREE_MODEL", "gemini-flash-lite-latest")
    url = _GEMINI.format(model=model)
    body = {
        "contents": [{"role": "user", "parts": [{"text": query}]}],
        "tools": [{"google_search": {}}],
    }
    async with httpx.AsyncClient(timeout=30, transport=_IPV4) as c:
        r = await c.post(url, params={"key": gkey}, json=body)
    try:
        parts = r.json()["candidates"][0]["content"]["parts"]
        text = "".join(p.get("text", "") for p in parts).strip()
        return {"text": text or "ไม่พบข้อมูล"}
    except Exception:  # noqa: BLE001
        return {"text": "ค้นไม่ได้ตอนนี้"}


async def generate_image(args: dict) -> dict:
    """Text → image via Pollinations (free, no key). Returns a flex card whose
    html block loads the generated PNG. Device renders it in the WebView."""
    prompt = (args.get("prompt") or "").strip()
    if not prompt:
        return {"text": "อยากให้วาดอะไรบอกได้เลยค่ะ"}
    enc = urllib.parse.quote(prompt)
    url = (f"https://image.pollinations.ai/prompt/{enc}"
           "?width=1024&height=1024&nologo=true")
    img = (f'<img src="{url}" alt="generated" '
           'style="width:100%;border-radius:12px;display:block"/>')
    return {"flex": {
        "header": {"icon": "sparkles", "title": "รูปที่วาดให้"},
        "body": [{"type": "html", "html": img}],
    }}


TOOLS = {
    "get_weather": weather,
    "get_currency": currency,
    "web_search": web_search,
    "generate_image": generate_image,
}
