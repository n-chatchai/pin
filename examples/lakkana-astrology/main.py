"""lakkana-astrology — sample EXTERNAL developer remote tool (team: Lakkana).

NOT platform code. The Lakkana team hosts this on their own server; ปิ่น's proxy
only routes blind calls here (by URL). It casts a Thai astrology birth chart with
Swiss Ephemeris (cast_chart.py, MIT — by Prem Chotipanit, github.com/batprem/
thai-astrology-skill), has the dev's own LLM interpret it, and returns a ready
flex card. Blind: receives only the birth facts, no identity/conversation.

Run:  uv run uvicorn main:app --host 0.0.0.0 --port 8092
"""

from __future__ import annotations

import json as _json
import os

import httpx
from fastapi import FastAPI, Request

from cast_chart import THAI_CITIES, cast_chart

app = FastAPI(title="lakkana-astrology (dev sample)")

# The DEVELOPER's own LLM key (not the platform's) — Lakkana pays for the reading.
_GKEY = os.environ.get("GEMINI_API_KEY", "")
_GEMINI = ("https://generativelanguage.googleapis.com/v1beta/models/"
           "gemini-flash-lite-latest:generateContent")

_AREAS = ["การงาน", "การเงิน", "ความรัก", "สุขภาพ"]


async def _interpret(client: httpx.AsyncClient, chart: dict, focus: str) -> dict:
    """Dev's LLM turns the raw chart into a Thai reading + per-area scores."""
    if not _GKEY:
        return {}
    prompt = (
        "คุณเป็นโหราจารย์ไทย ตีความ 'ดวงกำเนิด' ต่อไปนี้ (คำนวณด้วย Swiss Ephemeris) "
        f"โดยเน้นเรื่อง: {focus}. ตอบเป็นภาษาไทยล้วน อบอุ่นแต่ตรงไปตรงมา. "
        "ตอบเป็น JSON เท่านั้น: "
        '{"summary":"ภาพรวมดวง 2-3 ประโยค","scores":{"การงาน":0-100,'
        '"การเงิน":0-100,"ความรัก":0-100,"สุขภาพ":0-100},'
        '"advice":"คำแนะนำสั้น 1-2 ประโยค"}\n\n'
        f"ดวง:\n{_json.dumps(chart, ensure_ascii=False)}")
    try:
        r = await client.post(
            _GEMINI, params={"key": _GKEY},
            json={"contents": [{"parts": [{"text": prompt}]}],
                  "generationConfig": {"responseMimeType": "application/json"}})
        parts = r.json()["candidates"][0]["content"]["parts"]
        return _json.loads("".join(p.get("text", "") for p in parts).strip())
    except Exception:  # noqa: BLE001
        return {}


@app.post("/run")
async def run(request: Request) -> dict:
    b = await request.json()
    date = (b.get("date") or "").strip()       # YYYY-MM-DD (พ.ศ. or ค.ศ.)
    time = (b.get("time") or "12:00").strip()   # HH:MM
    place = (b.get("place") or "กรุงเทพ").strip()
    focus = (b.get("focus") or "ภาพรวม").strip()
    if not date:
        return {"text": "ขอวันเดือนปีเกิด (พ.ศ. หรือ ค.ศ.) ด้วยค่ะ เช่น 2535-01-15"}

    # Resolve place → lat/lon (fall back to provided coords, else Bangkok).
    key = place.lower() if place.encode().isascii() else place
    if key in THAI_CITIES:
        lat, lon = THAI_CITIES[key]
    elif b.get("lat") and b.get("lon"):
        lat, lon = float(b["lat"]), float(b["lon"])
    else:
        lat, lon = THAI_CITIES["กรุงเทพ"]

    try:
        chart = cast_chart(date, time, lat, lon, "tropical", 7.0)
    except Exception as e:  # noqa: BLE001
        return {"text": f"ผูกดวงไม่สำเร็จ: {e}"}

    lak = chart["ลัคนา"]
    # Force IPv4 — this VPS's IPv6 is geo-blocked by the Gemini API.
    async with httpx.AsyncClient(
        timeout=30, follow_redirects=True,
        transport=httpx.AsyncHTTPTransport(local_address="0.0.0.0")) as c:
        reading = await _interpret(c, chart, focus)

    scores = reading.get("scores") or {}
    body: list[dict] = []
    if reading.get("summary"):
        body.append({"type": "text", "text": reading["summary"]})
    body.append({"type": "divider"})
    body.append({"type": "kv", "k": "ลัคนา",
                 "v": f'{lak["ราศี"]} {lak["องศา"]}° · เจ้าเรือน'
                      f' {lak["ดาวเจ้าเรือน(ลัคนาธิปติ)"]}'})
    # Per-area strength bars (the "ดูดวง" archetype).
    body.append({"type": "bars",
                 "values": [int(scores.get(a, 60)) for a in _AREAS],
                 "labels": _AREAS})
    if reading.get("advice"):
        body.append({"type": "text", "text": reading["advice"], "color": "muted"})

    return {"flex": {
        "header": {"icon": "sparkles", "title": f"ดวง{focus}",
                   "subtitle": f'ลัคนา{lak["ราศี"]} · โหราศาสตร์ไทย'},
        "body": body,
        "footer": {"icon": "sparkles", "text": "Lakkana · โหราศาสตร์ไทย"},
    }}
