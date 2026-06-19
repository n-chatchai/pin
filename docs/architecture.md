# ปิ่น — Architecture (as built)

E2EE on-device agent. The **phone owns the agent + all memory**; the server is a
**blind, stateless proxy** (LLM router + minimal-arg tools + push scheduler). No
server-side conversation or user content at rest.

---

## 1. Top level — client ↔ server

```
┌──────────────────────── Phone (Flutter, iOS) ────────────────────────┐
│                                                                       │
│  LocalChatScreen ── ChatScaffold (composer · bubbles · flex · images) │
│        │ send(text/image)                                             │
│        ▼                                                              │
│  AgentSession ──── AgentStore  (history/facts/knowledge/prefs)        │
│   (per room)        └─ JSON file, iOS Data-Protection encrypted       │
│        │                                                              │
│        ▼                                                              │
│  DeviceBrain (agentic loop)                                           │
│   ├─ ToolRegistry ── local tools  (remember/recall/reminder/render)   │
│   │                └ remote tools (weather/currency/web_search)       │
│   ├─ ProxyClient  ── POST /infer   (chat-completions + tools)         │
│   └─ EmbedClient  ── POST /embed   (semantic memory vectors)          │
│                                                                       │
└───────────┬─────────────────┬───────────────────┬────────────────────┘
            │ /infer          │ /tool/*           │ /embed   (all TLS*)
            ▼                 ▼                   ▼
┌──────────────────────── Server (blind, stateless) ───────────────────┐
│  pin-proxy  (FastAPI, tmux restart-loop)                              │
│   /infer  ── free → Gemini (our key) │ paid → OpenRouter (user key)   │
│   /embed  ── Gemini embeddings (256-dim)                              │
│   /tool/* ── weather(place) · currency(base,quote) · web_search(q)    │
│   /schedule/register ── blind wake metadata {device,job_id,time}      │
│        └─ poller → APNs background push (no content)                  │
│  provider keys held here — NEVER in the app. Nothing stored/logged.   │
└──────────────────────────────────────────────────────────────────────┘
            │                                   │
            ▼                                   ▼
      Google Gemini  /  OpenRouter        Open-Meteo · Frankfurter
   (* TLS pending: dev is http://IP:8088 + ATS exception)
```

---

## 2. Agent internals (on device)

```
user turn ─► AgentSession.send(text, [imagePath])
              │  build system = persona + on-device facts + knowledge titles
              │  + current time/timezone
              ▼
        DeviceBrain.reply(history, text, imageB64?)
              │   messages = [system, ...history, user(+image)]
              ▼
        ┌──── loop (≤6 steps) ───────────────────────────────┐
        │  ProxyClient.infer(messages, tool declarations)     │
        │        ▼                                            │
        │  choices[0].message                                 │
        │   ├─ no tool_calls ─► return AgentReply(text)       │
        │   └─ tool_calls ─► for each call:                   │
        │        ToolRegistry.dispatch(name, args) ─► ToolResult
        │          ├─ terminal (flex/html card) ─► return now │
        │          └─ feedback (text) ─► append, continue     │
        └─────────────────────────────────────────────────────┘
              ▼
        AgentReply {text | flex}  ─► render bubble / FlexCardView
              │
              └─ persist clean transcript (user + assistant text) to AgentStore
```

**Tool placement (PII gate):** state/memory + side-effects stay on device;
network lookups go to blind remote APIs that receive only the narrow arg.

| Tool | Where | Sees |
|---|---|---|
| remember_fact / recall_knowledge | on-device | local memory (PII) |
| schedule_reminder | on-device | local notification |
| render_html | on-device | the card |
| get_weather / get_currency | **remote** /tool | place / base+quote only |
| web_search | **remote** /tool | the query only |

`recall_knowledge` = EmbedClient.embed(query) → cosine vs on-device vectors
(server only embeds the query text, never the stored knowledge).

---

## 3. Memory (on device, AgentStore)

```
AgentStore  (app support dir, JSON, encrypted at rest by iOS Data Protection)
 ├─ history[room]    rolling OpenAI messages (cap 20 turns)
 ├─ facts[room]      remembered facts (cap 40) → injected into system
 ├─ knowledge[room]  {title, summary, content, embedding[256]}  → cosine recall
 └─ prefs            persona / settings
```

---

## 4. Turn examples

```
"อากาศกรุงเทพ 3 วัน"
  brain → tool_call get_weather{place:"กรุงเทพ",days:3}
        → POST /tool/get_weather (server: place only) → Open-Meteo
        → {flex: carousel}  ─► terminal ─► FlexCardView (3-day cards)

[ส่งรูป] "นี่อะไร"
  brain → /infer messages=[..., user[text, image_url(base64)]] (free→Gemini)
        → text  ─► markdown bubble        (server sees image momentarily)

"เตือน 8 โมง กินยา"
  brain → tool_call schedule_reminder{text,time:08:00}
        → on-device flutter_local_notifications.zonedSchedule
        → fires at 08:00 even screen-off (no server, no APNs)

morning-news job (future, push)
  /schedule/register{device,job_id,08:00}  (blind metadata)
   8:00 → APNs background push → app wakes → AgentSession runs job → delivers
```

---

## 5. Privacy boundaries — who sees plaintext

| Hop | Sees |
|---|---|
| Phone | everything (owner) |
| **pin-proxy /infer** | the prompt momentarily (free tier) — not stored/logged |
| paid tier | OpenRouter sees prompt; **we don't** |
| /tool/* | only {place} / {base,quote} / {query} — no identity/convo/prefs |
| /embed | the text to embed (query / knowledge) |
| /schedule | {device, job_id, time} — no content |
| Gemini / OpenRouter | the inference payload (unavoidable for a cloud LLM) |

Server holds **no conversation, memory, or user content at rest**. (Cloud LLM
still sees inference input — true zero-knowledge needs an on-device model.)

---

## 6. Tech stack

| Layer | Tech |
|---|---|
| App | Flutter (Dart), flutter_rust_bridge + matrix-rust-sdk (auth/E2EE keys) |
| On-device agent | DeviceBrain loop, AgentStore (JSON+DataProtection), image_compress |
| LLM I/O | OpenAI chat-completions schema (text + tools + image_url) |
| Proxy | FastAPI + uvicorn (tmux restart-loop), httpx |
| Providers | Gemini (free, our key) · OpenRouter (paid, user key) |
| Tools | Open-Meteo (weather) · Frankfurter (FX) · Gemini grounding (web_search) |
| Push | blind scheduler + APNs (.p8) — pending creds |

---

## 7. Extending it (skills · tools · MCP · subagents)

How new capability is added without breaking the E2EE boundary — ToolRouter
(local/remote/subagent kinds + arg-sanitize), skill manifests, a proxy `/catalog`
for dynamic tools, and MCP fronted server-side — is specced in
[extensibility.md](extensibility.md).

---

## 8. Admin backoffice

A small internal console to manage the marketplace (tools · skills · MCP ·
subagents) and **publish a signed catalog** the devices pull. It manages *config
and manifests only* — never user content — so it stays inside the blind boundary.

> Status: **backend slice built** (not yet deployed). SQLite store
> (`store.py`, seeds from the legacy catalog + `PIN_MCP_SERVERS`), `/admin` router
> (`admin.py`: argon2 login → JWT cookie, tools list/toggle, other tabs read-only,
> Ed25519 catalog publish), HTMX+Jinja templates, `catalog.py`/`mcp.py` now read
> the DB. `Caddyfile` for TLS. Pending: device-side signature verification,
> richer editors (add/edit tool & MCP forms), and VPS deploy (install deps + set
> `PIN_ADMIN_EMAIL`/`PIN_ADMIN_PASSWORD`).

```
┌─────────── Admin (browser, owner-only) ───────────┐
│  React + Vite + Tailwind SPA                       │
│   tools · skills · subagents · MCP · catalog · logs│
└───────────────────────┬────────────────────────────┘
                        │  admin session (JWT cookie, not the device bearer)
                        ▼
┌──────────── Proxy · FastAPI ──────────────────────┐
│  /admin/*  (CRUD manifests, publish)   ← new       │
│  /catalog  (serves latest SIGNED snapshot)         │
│  /tool/* · /infer · /embed · MCP        (existing)  │
│        │                                           │
│        ▼  source of truth                          │
│   SQLite (catalog/skills/mcp/subagents/versions)   │
│   Ed25519 signing key (server-side)                │
└────────────────────────────────────────────────────┘
        device verifies the catalog signature with an embedded public key
```

### Stack

| Layer | Choice | Why |
|---|---|---|
| Admin API | **FastAPI `/admin` router** in the proxy process | reuse Python/httpx, one deploy, no new service |
| Store | **SQLite** (WAL) → Postgres only if it scales | catalog is small config; file-based, zero infra |
| Catalog integrity | **Ed25519-signed** manifest snapshot; device verifies | a tampered proxy can't inject a tool |
| Admin auth | email + password (**argon2**) → JWT cookie; OIDC later | separate realm from the device bearer; single owner now |
| Frontend | **HTMX + Jinja** templates served by FastAPI | zero build step, server-rendered; the mocks map straight to partials |
| Hosting | **Caddy + automatic TLS** (VPS already runs it) | one-line reverse proxy + Let's Encrypt, admin behind auth |
| Logs | tool-call **metadata only** (ts · tool · kind · argKeys · status) | stays blind — no conversation |

> Frontend is server-rendered HTMX (no Node toolchain): each tab is a Jinja
> partial swapped in via `hx-get`; toggles/forms post via `hx-post`. Move to a SPA
> only if the editors outgrow this.

### Data model (SQLite)

```
tools(name, kind, description, parameters_json, arg_keys_json, source, enabled, updated_at)
skills(name, description, instructions, requires_json, enabled)
subagents(name, description, system, tool_names_json, model, max_steps)
mcp_servers(name, url, headers_json, status)
mcp_tools(server, name, description, parameters_json, arg_keys_json, enabled)
catalog_versions(version, signed_blob, published_at, author, diff)
admin_users(email, pw_hash, role)
tool_logs(ts, tool, kind, arg_keys, status)        -- metadata only, no content
```

### Publish flow

```
edit rows  →  "Publish vN"  →  build manifest from ENABLED rows
           →  Ed25519 sign  →  store catalog_versions  →  /catalog serves it
device     →  fetch + verify signature  →  merge tools at runtime (§7)
```

This replaces today's hard-coded catalog source (`catalog.py` literals + the
`PIN_MCP_SERVERS` env) with DB-backed, signed, editable manifests — the proxy
endpoints (`/catalog`, `/tool/*`) stay the same shape, so the device needs no
change beyond signature verification.

---

## 9. Decommissioned (legacy server bot)

The earlier server-side path — Matrix bot (nio) + Postgres (pgvector) memory +
Redis/RQ worker + Alembic — is **stopped**. Code/schema kept (reversible); DB
data wiped. Replaced by the on-device agent above. See
[e2ee-mobile-agent.md](e2ee-mobile-agent.md) for the migration and
[backend-scale.md](backend-scale.md) for the old server design.
```
