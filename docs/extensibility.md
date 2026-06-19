# ปิ่น — Extensibility (skills · tools · function-calling · MCP · subagents)

How ปิ่น grows new capability **without breaking E2EE**. One rule governs all of
it: **the brain + all PII live on the phone; anything that touches the network is
blind and gets only minimal, declared args** (via the proxy). Every feature below
is designed to fit that boundary. See [architecture.md](architecture.md) for the
as-built base.

> Status: **live** (proxy deployed on the VPS; app 1.0.0+91). On-device:
> arg-sanitize PII gate, sandboxed subagents (`delegate`). Delivered dynamically
> through `/catalog`: tools, **skills** (instructions injected, per-user toggle),
> and **subagents** (merged with built-ins — developer-publishable). Proxy:
> SQLite store + admin backoffice (install/edit/publish, provider+pricing),
> MCP-fronting (`mcp.py`, argKeys pinned). The marketplace/platform model
> (developers bring MCP+subagents) is in [capability-sources.md](capability-sources.md);
> remaining gaps: developer portal + review, per-user OAuth vault, billing.

---

## 0. The one invariant

```
on-device  → may see identity, conversation, memory, prefs   (PII)
network    → may see ONLY the narrow declared args of one tool call
```

Tools never receive identity / raw conversation / preferences. This is enforced
in **code** (arg-sanitize at dispatch), not by convention.

---

## 1. Top-level shape

```
┌─────────────────── Phone (Dart, E2EE) ──────────────────┐
│ DeviceBrain (agentic loop)                               │
│   └─ ToolRouter ── dispatch + ARG-SANITIZE + SANDBOX     │
│        ├─ LocalTool   (PII ok)   remember/recall/remind  │
│        ├─ RemoteTool  (blind)    → proxy /tool/{name}     │
│        └─ Subagent    (sub-brain) delegate(researcher…)  │
│   └─ SkillRegistry ── manifests (prompt-frag + tool set) │
│        ├─ built-in (compiled)                            │
│        └─ catalog cache  ← GET /catalog (signed, no PII) │
└──────────────────────────┬───────────────────────────────┘
                           │ /infer /tool/* /catalog /embed
┌────────────────── Proxy (blind, server) ─────────────────┐
│ /catalog ── manifests: remote + MCP-fronted tools        │
│ /tool/{name} ── weather/fx/web · dynamic-http · MCP      │
│ MCP client(s) ── connect MCP servers (keys server-side)  │
│   enumerate tools → expose as /tool/mcp.{srv}.{tool}     │
└──────────────────────────────────────────────────────────┘
```

---

## 2. ToolRouter — replaces the static `ToolRegistry`

Every tool is one `ToolKind`:

| kind | runs where | sees | examples |
|---|---|---|---|
| `local` | on device | full PII | remember / recall / reminder / render / get_time |
| `remote` | proxy | only declared args | weather / fx / web_search · dynamic · **MCP** |
| `subagent` | on device (sub-brain) | full PII (inner loop) | researcher / planner |

**PII enforcement (the critical point):** `ToolRouter.dispatch` strips `args` to
only the keys declared in `declaration.properties` **before** any `remote` send.
A model that stuffs extra keys (a `note` with PII) cannot leak them.

Extend the tool type with `kind` + `argKeys` (the allowlist derived from the
declaration's properties):

```
AgentTool {
  declaration,         // OpenAI function schema (unchanged)
  kind,                // local | remote | subagent
  handler,             // local/subagent
  // remote: routed to proxy /tool/{name}; args sanitized to declared keys
}
```

Today's pieces this evolves from: [tools.dart](../lib/agent/tools.dart)
(`AgentTool`, `ToolRegistry`), [remote_tools.dart](../lib/agent/remote_tools.dart)
(`_remote`), dispatch loop in [device_brain.dart](../lib/agent/device_brain.dart).

---

## 3. Function-calling — already in place

OpenAI tools schema (text + tools + image_url) works. No change to the wire
format; only the registry around it grows. Declarations flow
`ToolRouter.declarations()` → `ProxyClient.infer(tools:)` → model `tool_calls` →
`ToolRouter.dispatch`.

---

## 4. Skills = manifests (add capability without editing code)

A **skill** bundles a prompt fragment + a tool subset (+ optional subagent):

A skill is a **prompt/knowledge pack**, aligned with the Claude Agent Skills
`SKILL.md` format ([awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills)):

```
Skill {                       // manifest = front-matter of SKILL.md
  name, description,          // description doubles as the model-facing trigger hint
  instructions,              // SKILL.md body → injected into _system() when ON
  resources?: [...],         // bundled reference files (read on demand)
  requires?: {               // dependency resolution
    tools:  [...],           // tool/function names this skill needs
    mcp:    [...],           // MCP servers that must be installed (§7)
    subagent?: SubagentSpec, // optional bundled subagent
  },
}
```

- **Mostly on-device-safe:** a skill is instructions/knowledge — it never leaves
  the phone. Only its `requires.tools` / `requires.mcp` touch the network, and
  those go through the same PII gate (arg-sanitize, §2).
- Toggled per user, persisted in prefs / [AgentStore](../lib/agent/agent_store.dart).
- Enabling a skill: its `instructions` are appended to the system prompt and its
  required tools are added to the room's registry for that turn. If a required MCP
  server isn't installed, the skill shows as **needs setup** (resolve in admin).
- Built-in skills compile with the app; new ones arrive via `/catalog` (§6),
  imported from a skills registry (e.g. officialskills.sh / awesome-agent-skills).

This is how "ปิ่น learns a new skill" happens with no app update.

> **Skill vs MCP:** a *skill* is *what to do* (prompt + knowledge, on-device); an
> *MCP server* is *a capability* (a remote tool, proxy-fronted). A skill often
> *requires* one or more MCP tools — e.g. an "email triage" skill requires the
> `gmail` MCP. Import skills and tools independently; the dependency links them.

---

## 5. Subagents — sub-brain, **on device**

A subagent must run on-device because it sees the conversation/PII; it uses the
proxy only for `/infer`. `delegate` is a `local` tool.

### 5.1 Manifest — Claude Code subagent format

A subagent is a markdown file with YAML front-matter, the same shape as
[awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents).
We adopt the **format**, not its (coding-focused) catalog.

```yaml
---
name: researcher
description: ใช้เมื่อต้องค้นหลายแหล่ง/หลายรอบกว่าจะได้คำตอบ   # → delegate enum + router hint
tools: web_search, recall_knowledge                        # → toolNames = sandbox allowlist
model: haiku                                               # → proxy model param (optional)
maxSteps: 6
---
คุณคือผู้ช่วยค้นคว้าของปิ่น. ค้นเว็บและความรู้ที่เก็บไว้หลายรอบถ้าจำเป็น
แล้วสรุปคำตอบที่ครบถ้วน ตรวจสอบได้ ภาษาไทย กระชับ. ห้ามมโน.   # → system (body)
```

| front-matter | SubagentSpec | note |
|---|---|---|
| `name` | `name` | — |
| `description` | `delegate` enum + router hint | how the main brain decides to delegate |
| `tools` | `toolNames[]` | **= the sandbox allowlist** |
| `model` | proxy `model` param | free → Gemini regardless; paid may honor |
| body | `system` | — |

```
SubagentSpec { name, description, system, toolNames[], model?, maxSteps = 6 }
```

### 5.2 Hand-off

```
main brain  (sees every subagent's description)
  └─ tool_call delegate(subagent:"researcher", task:"…")
       └─ child DeviceBrain(
              system   = spec.system,
              registry = ROUTER.subset(spec.toolNames),   // SANDBOX enforced here
              model    = spec.model,
              maxSteps = spec.maxSteps)               // isolated context, own history
       └─ bounded loop → return text → fed back to main brain as tool feedback
```

- **Isolated context** — the child keeps its own message history, so research
  noise never clutters the main thread.
- **On-device** — the sub-brain may see PII (it's just an inner loop); its
  network tools still pass the PII gate (§2).
- **Explicit, not magic** — unlike Claude Code's auto-router, the main brain
  picks a subagent by calling `delegate` (an auditable tool call). Inject the
  subagent descriptions into the system prompt so it knows when to.

**Sandbox is enforced at dispatch** (the child router holds *only* the subset),
fixing the legacy bot's gap where the global dispatch let a subagent call tools
outside its subset — and call `delegate` recursively. The subset excludes
`delegate` ⇒ no recursion.

Curate for an assistant (`researcher`, `planner`, `shopper`, `trip-planner`) —
ignore the upstream coding subagents (`code-reviewer`, `python-pro`, …).

---

## 6. Dynamic add — `/catalog` (replaces the old Postgres marketplace)

- Proxy serves `GET /catalog` → a list of manifests: `{name, description,
  parameters (JSON-schema), kind, argKeys}`. **Signed, contains no PII.**
- Device fetches, caches, and merges them into the `SkillRegistry`, so
  declarations update at **runtime** without rebuilding the app.
- Adding a tool / skill = add a manifest on the proxy. Nothing ships to the phone.

```
GET /catalog
→ [
    {name:"get_flight", kind:"remote", parameters:{...}, argKeys:["from","to","date"]},
    {name:"notion_search", kind:"remote", parameters:{...}, argKeys:["query"]},   // MCP-fronted
    ...
  ]
```

---

## 7. MCP — lives at the **proxy**, not the device

Why server-side: MCP servers need auth/keys, hiding the user's IP, and keeping the
blind model intact. Putting an MCP client on each phone would leak the IP, can't
hold secrets, and bloats the app.

- Proxy runs MCP client(s), connecting to MCP servers (config + keys server-side).
- It enumerates each server's tools and exposes them as
  `/tool/mcp.{server}.{tool}`, listing them in `/catalog` with their JSON schema.
- The **device sees them as ordinary `remote` tools** — unaware MCP is behind
  them. The existing PII gate (arg-sanitize → minimal args) already covers them.
- Device needs no MCP client. App stays light; E2EE boundary unchanged.

```
phone → /tool/mcp.notion.search {query:"Q3 plan"}   (only the declared arg)
proxy → MCP(notion).callTool("search", {query})      (keys server-side)
      → result text/flex → back to phone
```

### 7.1 Curated starter catalog

The MCP ecosystem ([awesome-mcp-servers](https://github.com/punkpeye/awesome-mcp-servers),
~50 categories) is the *source* the catalog fronts — but ปิ่น does **not** auto-front
all of it. Start from the audited reference servers
([modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers))
mapped to assistant use-cases:

| category | MCP server | skill | declared arg keys (blind) |
|---|---|---|---|
| Calendar | google-calendar | ผู้ช่วยปฏิทิน | title · start · end · query |
| Knowledge / Notes | notion · obsidian | สมุดบันทึก | query · title · content |
| Search / Web | brave-search · fetch | ค้นเว็บ | query · url |
| Memory (graph) | mcp-memory | ความจำ | entity · relation |
| Communication | slack · gmail | สื่อสาร | channel/to · text |
| Files / Cloud | filesystem · gdrive | ไฟล์ | path · query |
| Location / Travel | google-maps | เที่ยว | place · from · to · date |
| Time | time | (built-in get_time) | tz |

**Onboarding policy — allowlist + audit before fronting:**

1. A server is added to the catalog only after review (no auto-front of arbitrary
   community servers; many in the awesome-list are unaudited).
2. For each MCP tool, pin its `argKeys` allowlist from the tool's JSON schema —
   the arg-sanitizer (§2) drops everything else before the call.
3. The MCP server's auth/keys live **only** on the proxy; the device never holds
   them and never connects to the MCP server directly.
4. Each MCP-backed skill is **opt-in per user**. Enabling it is the consent that
   its declared args may reach that server (surface this in the skill's privacy
   line). Default: off.

---

## 8. Privacy recap (per feature)

| feature | new plaintext exposure | mitigation |
|---|---|---|
| remote tool | declared args only | arg-sanitize at dispatch |
| dynamic (catalog) | same as remote | manifest signed; argKeys allowlist |
| MCP | declared args reach the MCP server (via proxy) | server-side keys; minimal args; user opts in per skill |
| subagent | none new (runs on device) | sandboxed tool subset |
| skill toggle | none | prefs on device |

Server still holds **no conversation / memory / user content at rest**. A cloud
LLM (and any MCP server you enable) still sees its own inference/tool input — the
unavoidable floor short of an on-device model.

---

## 9. Build order

1. **ToolRouter + arg-sanitize** — refactor `ToolRegistry`; add `kind` / `argKeys`.
   Closes the real PII gap shipping today. (Dart, immediate effect.)
2. **Subagent on-device** — `delegate` local tool + child `DeviceBrain` + enforced
   sandbox. Restores what the decommissioned bot lost.
3. **SkillRegistry + manifest** — built-in skills first; per-user toggle.
4. **Proxy `/catalog`** + dynamic remote tool from manifest — add tools without an
   app update.
5. **MCP client at the proxy** → exposed as remote tools — MCP arrives free through
   the catalog.

Steps 1–2 live in the app (ship in a build); 4–5 live in the proxy (add tools
without shipping). Start with **1 → 2**.

---

## 10. Decommissioned reference (legacy bot)

The Python bot had a working version of most of this, now stopped: unified
registry + dynamic HTTP tools (`bot/pin_bot/tools/`), a `researcher` subagent
(`bot/pin_bot/subagents/`), MCP only a stub. The patterns are reused above but
re-homed to the E2EE split (brain on device, blind tools/MCP on the proxy).
