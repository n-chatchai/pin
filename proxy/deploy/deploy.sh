#!/usr/bin/env bash
# One-shot deploy from your Mac: rsync code -> VPS ~/pin/proxy, push .env (only
# if a local one exists), uv sync, restart the systemd --user unit, health-check.
# Matches prod: systemd (pin-proxy.service), NOT tmux. Caddy fronts 8088 as
# pin-gateway.tokens2.io — its config lives in root /etc/caddy/Caddyfile, not here.
# Never overwrites the VPS .env without a local one. Never runs root.
#   deploy/deploy.sh user@VPS_IP [remote-dir]      (remote-dir default: pin/proxy)
set -euo pipefail

DEST="${1:?usage: deploy.sh user@host [remote-dir]}"
REMOTE_DIR="${2:-pin/proxy}"
HERE="$(cd "$(dirname "$0")" && pwd)"     # deploy/ dir
PROXY_DIR="$(dirname "$HERE")"            # proxy/ dir
# systemctl --user over ssh needs the runtime dir pointed at the login session.
SYSTEMD_ENV='export XDG_RUNTIME_DIR=/run/user/$(id -u)'

echo "==> 1/4 sync code -> $DEST:$REMOTE_DIR  (keeps remote .env / *.db / *.json)"
ssh "$DEST" "mkdir -p \"$REMOTE_DIR\""
rsync -avz --delete \
  --exclude '.venv/' --exclude '.env' --exclude '*.p8' \
  --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' \
  --exclude '*.json' --exclude 'proxy.log' --exclude '__pycache__/' \
  "$PROXY_DIR"/ "$DEST":"$REMOTE_DIR"/

echo "==> 2/4 push secrets (.env + APNs key) — only if a local one exists"
if [ -f "$PROXY_DIR/.env" ]; then
  scp "$PROXY_DIR/.env" "$DEST":"$REMOTE_DIR"/.env
  ssh "$DEST" "chmod 600 \"$REMOTE_DIR/.env\""
else
  echo "   no local proxy/.env — leaving the VPS .env untouched"
fi
# APNs auth key (.p8) for the agentic-job push scheduler. Drop the file from
# Apple at proxy/AuthKey.p8; set APNS_KEY_PATH in .env to ~/pin/proxy/AuthKey.p8.
for p8 in "$PROXY_DIR"/*.p8; do
  [ -e "$p8" ] || continue
  scp "$p8" "$DEST":"$REMOTE_DIR"/"$(basename "$p8")"
  ssh "$DEST" "chmod 600 \"$REMOTE_DIR/$(basename "$p8")\""
done

echo "==> 3/4 uv sync + restart systemd unit"
ssh "$DEST" "$SYSTEMD_ENV; bash \"$REMOTE_DIR/deploy/setup.sh\" \"\$HOME/$REMOTE_DIR\" && systemctl --user restart pin-proxy"

echo "==> 4/4 health check (/health)"
for i in 1 2 3; do
  sleep 6
  H="$(ssh "$DEST" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088/health 2>/dev/null")"
  echo "[$i/3] /health=$H"
  [ "$H" = "200" ] && break
done

echo "Deployed. Gateway: https://pin-gateway.tokens2.io  ·  logs: ssh $DEST 'journalctl --user -u pin-proxy -f'"
echo "VPS .env keys: PIN_ADMIN_EMAIL, PIN_ADMIN_PASSWORD, PIN_ADMIN_SECRET, PIN_CATALOG_KEY"
echo "APNs (agentic-job push) .env keys: APNS_KEY_PATH (=~/pin/proxy/AuthKey.p8),"
echo "  APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC=io.tokens2.pin, APNS_ENV=sandbox|production"
