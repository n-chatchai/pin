#!/usr/bin/env bash
# Deploy the static ปิ่น marketing site to the VPS. NO sudo / NO Cloudflare needed
# here — just rsyncs site/ -> pace6@VPS:~/pin/site, which Caddy serves as
# pin.tokens2.io. Re-run any time after editing the site.
#   site/deploy.sh [user@host]      (default: pace6@62.146.235.57)
#
# ── ONE-TIME SETUP (needs sudo + Cloudflare, done by the owner) ───────────────
# 1. Cloudflare DNS: add record  pin  →  A 62.146.235.57  (Proxied / orange).
# 2. Add this block to /etc/caddy/Caddyfile (sudo), then reload:
#       pin.tokens2.io {
#           tls /etc/ssl/cloudflare/tokens2.io.pem /etc/ssl/cloudflare/tokens2.io.key
#           encode gzip
#           root * /home/pace6/pin/site
#           try_files {path} {path}.html {path}/index.html
#           file_server
#       }
#    sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
# (Origin cert is *.tokens2.io, so it already covers pin.tokens2.io.)
set -euo pipefail
DEST="${1:-pace6@62.146.235.57}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ssh "$DEST" 'mkdir -p ~/pin/site'
rsync -avz --delete --exclude '.DS_Store' --exclude 'deploy.sh' "$HERE"/ "$DEST":'pin/site/'
echo "Synced site/ -> $DEST:~/pin/site"
echo "Live at https://pin.tokens2.io once DNS + the Caddy block are in place (see header)."
