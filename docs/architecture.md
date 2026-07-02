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
│   └─ ProxyClient  ── POST /infer   (chat-completions + tools)         │
│                                                                       │
└───────────┬─────────────────┬───────────────────┬────────────────────┘
            │ /infer          │ /tool/*           │ /catalog
            ▼                 ▼                   ▼
┌──────────────────────── Server (Rust, axum) ─────────────────────────┐
│  pin-proxy (Rust backend)                                            │
│   /infer  ── free → Gemini (our key) │ paid → OpenRouter (user key)   │
│   /tool/* ── weather(place) · currency(base,quote) · web_search(q)    │
│   /catalog ── returns tools, skills, subagents (backward compatible)  │
│  provider keys held here — NEVER in the app. Nothing stored/logged.   │
└──────────────────────────────────────────────────────────────────────┘
            │                                   │
            ▼                                   ▼
      Google Gemini  /  OpenRouter        Open-Meteo · Frankfurter
```

---

## 2. Agent internals (on device)

**Interaction Modes**:
With the new Assistant Architecture, the client supports multiple interaction modes defined in the backend `metadata_json`:
1. **Delegation Mode**: Main agent delegates a bounded task to a subagent (DeviceBrain sandbox).
2. **Handoff Mode**: Main agent transfers session control entirely to the assistant (UI switches `currentBrain`).

**Tool placement (PII gate):** state/memory + side-effects stay on device;
network lookups go to blind remote APIs that receive only the narrow arg.

| Tool | Where | Sees |
|---|---|---|
| remember_fact / recall_knowledge | on-device | local memory (PII) |
| schedule_reminder | on-device | local notification |
| get_weather / get_currency | **remote** /tool | place / base+quote only |
| web_search | **remote** /tool | the query only |

---

## 3. Data model (SQLite Backend - Assistant Architecture)

The Rust backend utilizes a unified **Assistant** architecture featuring Many-to-Many relationships to allow resource sharing:

```sql
assistants(name, label, description, version, status)
connectors(name, kind, endpoint, auth_json, status)
capabilities(name, kind, connector_name, system_prompt, metadata_json, enabled)
assistant_capabilities(assistant_name, capability_name)  -- M:M mapping
admin_users(email, role)
system_settings(key, value)
```

- **Assistants**: The overarching package (e.g. `tutor`, `shopper`).
- **Connectors**: External pipes (e.g. `mcp`, `oauth2`).
- **Capabilities**: The actual tools, skills, and subagents.
- **Backward Compatibility**: The `/catalog` endpoint reads from `capabilities` and maps them back into the `tools`, `skills`, and `subagents` JSON arrays expected by the Flutter client.

---

## 4. Tech stack

| Layer | Tech |
|---|---|
| App | Flutter (Dart), flutter_rust_bridge + matrix-rust-sdk (auth/E2EE keys) |
| On-device agent | DeviceBrain loop, AgentStore (JSON+DataProtection) |
| Proxy | **Rust (Axum + Tokio + SQLx)** |
| Providers | Gemini (free, our key) · OpenRouter (paid, user key) |
| DB Store | **SQLite (WAL)** |
