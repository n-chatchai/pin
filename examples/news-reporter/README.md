# news-reporter — sample EXTERNAL developer capability

This is **example third-party developer code** — it is NOT part of ปิ่น's
platform (`proxy/pin_proxy`). A developer hosts this on **their own server**;
ปิ่น's proxy only *routes* to it (blind, by URL). Kept in this repo purely as a
reference others can copy.

## What it is

A **remote subagent**: an agentic HTTP endpoint the developer hosts. ปิ่น calls
it with a blind cursor (`since`); it fetches a feed, and returns a ready **flex
card** of items newer than the cursor, plus the new cursor. No new → `{skip}`.

```
ปิ่น proxy ──POST /run {url, since}──▶ this service (dev's server)
                                         fetch RSS → compose flex card
            ◀──{flex, cursor} | {skip}──
```

- **Blind**: receives only `{url, since}` — no identity, no conversation.
- **Dev owns**: the model/LLM (if any), the card design, the hosting + cost.
- **Platform (ปิ่น)**: routes the call, enforces argKeys, renders the flex.

## Run (the developer does this on their box)

    uv run uvicorn main:app --host 0.0.0.0 --port 8090

Then a ปิ่น admin registers a tool `news_reporter` whose endpoint points here.

## Contract

POST `/run`  body `{"url": "...", "since": "<last guid|''>"}`
→ `{"flex": {...}, "cursor": "<newest guid>"}`  (new items)
→ `{"skip": true, "cursor": "<newest guid>"}`   (nothing new)
→ `{"text": "..."}`                              (error/info)
