# ปิ่น — Capability sources (skill · MCP · subagent), end-to-end

The three external ways to extend what ปิ่น can do, each with: **what it is**,
**how to use it**, and **how its output renders** (text · flex · html). All flow
through the catalog and stay inside the E2EE boundary (see
[extensibility.md](extensibility.md)). The app shows them as plain-language
"ความสามารถ" (provider + pricing); the user never sees the source type.

| source | lives where | the model calls | sees |
|---|---|---|---|
| **skill** | on device (prompt pack) | — (it's instructions, not a tool) | nothing — just guides the model |
| **MCP** | proxy-fronted (remote) | a remote tool | only the declared args |
| **subagent** | on device (sub-brain) | `delegate` | full PII (inner loop) |

---

## 1. Skill — a prompt/knowledge pack

**What:** a `SKILL.md`-shaped manifest: `name · description · instructions ·
requires{tools,mcp}`. The body (`instructions`) is injected into the system
prompt when the skill is ON. Pure guidance — no network, no PII leaves the phone.

**How to use:**
- admin installs it from the registry (source: awesome-agent-skills) → it lands
  in the catalog with `kind:"skill"` + its `instructions`.
- device fetches `/catalog`, and for each enabled skill injects `instructions`
  into the persona. Toggle in the app ("ความสามารถ" → on/off).
- it usually `requires` some tools (e.g. `web_search`) — those must also be in
  the catalog.

**Rendering:** the skill only steers the model; the *reply* is whatever the model
then produces — plain **text**, or it may call a tool that returns a **flex**
card, or `render_html` for **html**. e.g. *สรุปข่าวเช้า* → text bullets, or a
flex list.

```
admin install skill → /catalog{kind:skill,instructions}
device: isSkillOn → inject instructions → model follows → text / flex / html
```

## 2. MCP — an external tool, fronted by the proxy

**What:** a tool exposed by an MCP server (calendar, Notion, Gmail, search …).
The proxy holds the server's keys and speaks MCP; the device sees an ordinary
remote tool. Declared args only (argKeys allowlist).

**How to use:**
- admin installs an MCP server from the registry (source: awesome-mcp-servers),
  pins each tool's `argKeys`, fills the server URL/key on the proxy.
- its tools appear in `/catalog` with `kind:"mcp"`; the device adds them to the
  tool registry at runtime.
- the model calls the tool → `/tool/{name}` → proxy routes to the MCP server →
  result back.

**Rendering:** the proxy tool returns `{text}` (fed back, model phrases it →
**text**) or `{flex}` (a card shown as-is → **flex**). HTML is produced by the
on-device `render_html` if the model chooses to format a table/layout.

```
model → /tool/notion_search{query} → proxy → MCP(notion) → {text|flex} → bubble/card
```

> Needs a live MCP server to actually call. Until one is configured the catalog
> entry shows in the app (priced/locked) but a call returns a graceful error.

## 3. Subagent — a sub-brain, on device

**What:** a focused helper (Claude-format `name · description · system · tools ·
model`). The main brain hands it a task via the `delegate` tool; it runs a
bounded loop in a **sandboxed** tool subset and returns text.

**How to use:**
- a developer publishes the subagent manifest → it ships in `/catalog` with
  `kind:"subagent"` (name/description/system/toolNames/maxSteps). The device
  loads it **dynamically** (merged with the built-ins) — no app update.
- the main brain calls `delegate(subagent, task)` when a job needs several rounds
  (e.g. *researcher*: search + recall, multi-step, summarize; *planner*: build an
  HTML card).
- runs on device (own isolated context); its network tools still pass the PII
  gate; cannot call `delegate` (no recursion). The subagent is hidden from the
  user's "ความสามารถ" list — it's an internal helper, surfaced only via the
  "✨ ใช้: …" hint.

**Rendering:** the subagent returns **text**; that text is fed back to the main
brain, which phrases the final reply (text), or may wrap it in a **flex**/**html**
card. The user just sees the answer + a "✨ ใช้: ค้นเชิงลึก" hint.

```
brain → delegate(researcher, task) → child brain (subset) → text → brain → reply
```

---

## Rendering recap (all sources)

| output | how it's produced | UI |
|---|---|---|
| **text** | model `content`, or a tool's `{text}` it phrases | markdown bubble |
| **flex** | a tool returns `{flex}` (terminal) | FlexCardView (e.g. weather carousel) |
| **html** | `render_html(html,title)` (terminal) | flex card with an html block |

Every reply also carries `usedTools` → the app shows a faint **"✨ ใช้: …"** hint
naming the capability used.

---

## Platform / marketplace model

ปิ่น is a **two-sided marketplace**: third-party **developers** bring the
capabilities; **we** run the platform.

| | brings | hosts |
|---|---|---|
| **Developer** | MCP (endpoint + tool schemas + `argKeys` + auth) · subagent (prompt + toolset) · provider + pricing | **dev hosts their own MCP**; a subagent is just a prompt (nothing to host) |
| **Platform (us)** | catalog · on-device agent · billing · **PII gate + audit** · OAuth vault | catalog + agent + the proxy that routes to the dev's MCP |
| **User** | their account (OAuth) + payment | — |

Flow: developer submits → **review/audit** (argKeys can't exceed declared; no
identity/conversation/prefs may be requested) → published to `/catalog` → user
installs (free / onetime / subscription) → revenue share to the developer.

What the platform **enforces** (because capabilities are third-party):
- **arg-sanitize** — strip args to the developer's declared `argKeys` before any
  MCP call; identity/conversation/prefs never leave the device.
- **sandbox** — a subagent only sees its declared tool subset; no `delegate`.
- **OAuth vault** — the user's token for a dev service is held server-side per
  user (the one consented trade-off, made explicit at "เชื่อมบัญชี").
- review + rating + report before/after publish.

Build gaps for this model: **developer portal + review queue**, **MCP connection
registry + per-user OAuth**, **billing/revenue-share**. (Subagents already flow
dynamically through the catalog as of this version; the owner admin can install,
the dev-submit layer is next.)
