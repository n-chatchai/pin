# lakkana-astrology — sample EXTERNAL developer capability (team: Lakkana)

**Example third-party developer code** — NOT part of ปิ่น's platform
(`proxy/pin_proxy`). The **Lakkana** team hosts this on **their own server**;
ปิ่น's proxy only *routes* to it (blind, by URL). Kept in this repo as a
reference others can copy.

## What it is

A **remote tool** `thai_astrology`: ปิ่น calls it with blind birth facts; it
casts a Thai astrology chart (Swiss Ephemeris), the dev's own LLM interprets it,
and it returns a ready **flex card** (ลัคนา + per-area strength bars + reading).

```
ปิ่น proxy ──POST /run {date,time,place,focus}──▶ this service (Lakkana's server)
                                                  cast_chart → LLM → flex card
            ◀──────────── {flex} ────────────────
```

- **Blind**: receives only `{date, time, place, focus}` — no identity, no chat.
- **Lakkana owns**: the LLM (its own key), the card design, hosting + cost.
- **Platform (ปิ่น)**: routes the call, enforces argKeys, renders the flex.

## Attribution

`cast_chart.py` (Swiss Ephemeris chart casting) is vendored from
**thai-astrology-skill** by Prem Chotipanit — MIT License
(github.com/batprem/thai-astrology-skill). Lakkana wraps it as a hosted service.

## Run (Lakkana does this on their box)

    uv run uvicorn main:app --host 0.0.0.0 --port 8092

Then a ปิ่น admin registers a tool `thai_astrology` whose endpoint points here.

## Contract

POST `/run` body `{"date":"2535-01-15","time":"08:30","place":"กรุงเทพ","focus":"การงาน"}`
→ `{"flex": {...}}`            (the reading card)
→ `{"text": "..."}`           (need more info / error)
