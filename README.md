# ปิ่น (pin)

A private, end-to-end-encrypted chat app with an on-device AI assistant.
Conversations are real Matrix E2EE — the server never sees message content. The
assistant ("ปิ่น") runs on the device and reaches a blind LLM proxy for
inference and tools, so no identity or conversation context leaves the phone
beyond the encrypted channel.

This is a monorepo: the Flutter app plus the small set of server components it
talks to.

## Layout

| Path | What it is | Stack |
|------|------------|-------|
| `lib/`, `android/`, `ios/`, `rust/` | **Flutter app** — E2EE chat (matrix-rust-sdk via flutter_rust_bridge) + on-device agent | Dart / Rust |
| `backend-rust/` | **Unified backend** — blind LLM proxy (Gemini free / OpenRouter paid), hosted tools + MCP host, catalog, push scheduler, and admin backoffice (auth via tuwunel SSO). Single binary; holds no prompts. | Rust (axum) |
| `k8s/` | k3s manifests + deploy for `backend-rust` (Traefik ingress, cert-manager) | YAML |
| `design/` | Design system — colours, fonts, voice, Flex card mockups | HTML |
| `docs/` | Project docs | — |

The chat backend is a [tuwunel](https://github.com/matrix-construct/tuwunel)
Matrix homeserver (not in this repo).

## App

```bash
flutter pub get
flutter run --release          # debug build crashes standalone; use --release on device
```

Build-time defines:

- `--dart-define=PIN_REG_TOKEN=<token>` — registration token for the homeserver
- `--dart-define=PIN_PROXY_URL=<url>` — override the LLM proxy base (default: hosted gateway)

The app authenticates the proxy with the user's own Matrix access token (no
static API key ships in the binary).

## Proxy

```bash
cd proxy
uv sync
uv run pin-proxy               # binds 127.0.0.1:8088
```

Auth: each request carries the caller's Matrix access token, validated against
the homeserver `whoami` (`PIN_HOMESERVER`). The proxy stores/logs no
prompt/response content.

## Admin

A separate FastAPI app that shares the proxy's SQLite store via a path
dependency (so the `proxy/` dir must sit alongside it).

```bash
cd admin
uv sync
uv run pin-admin               # binds 0.0.0.0:8800 (PIN_ADMIN_PORT)
```

Auth is the Matrix (tuwunel) account: sign in with a ปิ่น username/password.
Owners listed in `PIN_ADMIN_OWNERS` get the full backoffice; everyone else lands
in the developer portal.

Key env: `PIN_HOMESERVER`, `PIN_ADMIN_OWNERS` (comma-separated `@user:domain` or
localparts), `PIN_CATALOG_KEY` (Ed25519 PEM for signing the published catalog).

## Security notes

- Chat is Matrix E2EE; the recovery key is held only by the user — losing it
  means encrypted history can't be recovered.
- Messages sent to third-party AI providers (Gemini, OpenAI, …) are **not**
  E2E-encrypted at the provider; the proxy stays blind but the provider sees the
  prompt.
- Secrets live in `.env` / VPS only and are gitignored — never commit keys,
  `*.db`, or `local.properties`.
