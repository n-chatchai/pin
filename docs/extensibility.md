# ปิ่น — Extensibility (Assistants · Skills · Tools · MCP)

How ปิ่น grows new capability **without breaking E2EE**. One rule governs all of
it: **the brain + all PII live on the phone; anything that touches the network is
blind and gets only minimal, declared args** (via the proxy). Every feature below
is designed to fit that boundary. See [architecture.md](architecture.md) for the
as-built base.

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
                           │ /infer /tool/* /catalog
┌────────────────── Proxy (Rust, server) ──────────────────┐
│ /catalog ── backward-compatible manifest of capabilities │
│ /tool/{name} ── weather/fx/web · dynamic-http · MCP      │
│ MCP client(s) ── connect MCP servers (keys server-side)  │
└──────────────────────────────────────────────────────────┘
```

---

## 2. Assistant Architecture (The Package Model)

Extensibility is now governed by the **Assistant Architecture**. An assistant is a packaged use-case (e.g., `gmail_summarizer`, `shopper`, `tutor`).

When an Assistant is installed in the Rust backend, it populates a Unified M:M Data Model:
- **`assistants`**: The overarching package metadata.
- **`connectors`**: Required external pipes (e.g., OAuth, MCP Servers).
- **`capabilities`**: The concrete tools, skills, or subagents.

The proxy backend flattens these capabilities and serves them backward-compatibly via the `/catalog` endpoint.

---

## 3. Interaction Modes

When defining a subagent capability, the `metadata_json` field specifies its `interaction_mode`. This instructs the Flutter client on how to route user interaction:

- **Delegation Mode (`interaction_mode: "delegate"`)**
  The main agent retains control. It calls the subagent as a tool, spinning up a child `DeviceBrain` in a sandboxed `ToolRegistry`. The subagent performs the work and returns the result text to the main agent.
  *Example: researcher, shopper*

- **Handoff Mode (`interaction_mode: "handoff"`)**
  The main agent completely transfers control of the UI chat session to the subagent. The user interacts directly with the subagent until control is returned.
  *Example: tutor, language_partner*

---

## 4. Admin backoffice

A Rust-based admin console manages the marketplace (Assistants, Connectors, Capabilities). It manages *config and manifests only* — never user content — so it stays inside the blind boundary.
