# Edge migration: Caddy → k3s Traefik (DONE 2026-07-01)

k3s Traefik is now the **sole edge proxy** on :443/:80. Caddy retired. All kept hosts
served directly by Traefik → host services. Cloudflare fronts every domain.

## What runs where

- **Edge**: k3s Traefik (`kube-system`), svclb binds host :80/:443. Entrypoints
  `web` (:8000 ← :80) and `websecure` (:8443 ← :443).
- **Host services** (rootless systemd `--user`, run as pace6) — each **dual-binds
  `127.0.0.1` + `10.42.0.1`** (cni0 host IP; pods reach the host there):
  | Service | Port | Unit |
  |---|---|---|
  | tuwunel (Matrix) | 6167 | `tuwunel.service` (`address = ["127.0.0.1","10.42.0.1"]`) |
  | tuwunel-admin | 8009 | `tuwunel-admin.service` (config.toml `bind`) |
  | pin-gateway (pin-proxy) | 8088 | already 0.0.0.0 |
  | pin-admin (uvicorn) | 8800 | `pin-admin.service` (`--host 10.42.0.1`) |
  | lakkana (gunicorn) | 9000 | `lakkana.service` (dual `--bind`) |
  | taemdee (gunicorn) | 9100 | `taemdee.service` (dual `--bind`) |
  | lakkana-scheduler / taemdee-worker | — | sidecars, portless |
- **Cluster glue** (namespace `pin`): per host a `Service` + `Endpoints`→`10.42.0.1:PORT`
  and an `IngressRoute` (`traefik.io/v1alpha1`, entrypoint `websecure`) matching `Host(...)`.

## TLS

- **pin-*.tokens2.io**: Cloudflare SSL = **Full (non-strict)** → Traefik default
  self-signed cert accepted. IngressRoute `tls: {}`.
- **lakkana.app / taemdee.com** (CF Full-**Strict**): **cert-manager + Let's Encrypt**
  (ClusterIssuer `letsencrypt-prod`, HTTP-01 via Traefik). `Certificate` → secret
  `lakkana-tls` / `taemdee-tls`, referenced by `IngressRoute.tls.secretName`. Auto-renews.

## Matrix / SSO specifics

- tuwunel **self-serves** `/.well-known/matrix/client` via `[global.well_known] client=...`
  (it 404s it otherwise — Caddy used to serve it statically).
- "Sign in with Google" = `m.login.sso`; OAuth client now under GCP project
  **pin-ai-b9d8a** (`143626975650-qval...`), configured in `tuwunel.toml`
  `[[global.identity_provider]]`.

## Dropped (were on Caddy, intentionally not migrated)

chat.tokens2.io (old Synapse), bz.tokens2.io, llama.tokens2.io, livekit.tokens2.io.

## Gotchas

- Services bound to `10.42.0.1` only exist while k3s/cni0 is up → on reboot they may
  fail to bind until k3s starts (systemd `Restart` recovers). Dual-binding `127.0.0.1`
  keeps them usable locally regardless.
- `systemctl --user` must run **as pace6**, not via `sudo`/root (root has a different
  user manager). Linger is enabled so user units start at boot.
- Don't restart Caddy — on start it tries to grab :443 and fights Traefik's svclb.

## Rollback

Stop k3s (`/usr/local/bin/k3s-killall.sh`) frees :443/:80; re-point Caddyfile to :443 and
restart Caddy. (Caddy config was last changed live via admin API :2019, not the file.)
