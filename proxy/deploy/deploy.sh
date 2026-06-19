#!/usr/bin/env bash
# One-shot deploy from your Mac (same flow as the bot): sync code, push .env,
# build venv, (re)start the proxy in tmux, health-check. NEVER overwrites the
# VPS .env unless you have a local one to push. Never runs root.
#   deploy/deploy.sh user@VPS_IP [remote-dir]      (remote-dir default: pin-proxy)
set -euo pipefail

DEST="${1:?usage: deploy.sh user@host [remote-dir]}"
REMOTE_DIR="${2:-pin-proxy}"
HERE="$(cd "$(dirname "$0")" && pwd)"     # deploy/ dir
PROXY_DIR="$(dirname "$HERE")"            # proxy/ dir

echo "==> 1/4 sync code -> $DEST:$REMOTE_DIR  (keeps remote .env / *.db / *.json)"
ssh "$DEST" "mkdir -p \"$REMOTE_DIR\""
rsync -avz --delete \
  --exclude '.venv/' --exclude '.env' \
  --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' \
  --exclude '*.json' --exclude 'proxy.log' --exclude '__pycache__/' \
  "$PROXY_DIR"/ "$DEST":"$REMOTE_DIR"/

echo "==> 2/4 push secrets (.env) — only if a local one exists"
if [ -f "$PROXY_DIR/.env" ]; then
  scp "$PROXY_DIR/.env" "$DEST":"$REMOTE_DIR"/.env
else
  echo "   no local proxy/.env — leaving the VPS .env untouched"
fi

echo "==> 3/4 build venv + (re)start proxy"
ssh "$DEST" "bash \"$REMOTE_DIR/deploy/setup.sh\" \"$REMOTE_DIR\" && bash \"$REMOTE_DIR/deploy/run.sh\" \"$REMOTE_DIR\""

echo "==> 4/4 health check (/health + /catalog)"
for i in 1 2 3; do
  sleep 6
  H="$(ssh "$DEST" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088/health 2>/dev/null")"
  echo "[$i/3] /health=$H"
  [ "$H" = "200" ] && break
done

echo "Deployed. Admin: https://<domain>/admin  ·  logs: ssh $DEST 'tail -f $REMOTE_DIR/proxy.log'"
echo "Set on the VPS .env: PIN_ADMIN_EMAIL, PIN_ADMIN_PASSWORD, PIN_ADMIN_SECRET, PIN_CATALOG_KEY"
