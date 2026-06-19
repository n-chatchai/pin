#!/usr/bin/env bash
# Start the ปิ่น admin backoffice in a detached tmux session with a restart loop.
# Shares the proxy's SQLite store; needs the `proxy` dir as a sibling (path dep).
#   deploy/run.sh [app-dir]
set -euo pipefail

APP_DIR="${1:-${APP_DIR:-$HOME/pin-admin}}"
export PATH="$HOME/.local/bin:$PATH"
cd "$APP_DIR"

tmux kill-session -t pin-admin 2>/dev/null || true
tmux new-session -d -s pin-admin \
  "while true; do echo \"[admin] starting \$(date)\"; uv run pin-admin; echo \"[admin] exited rc=\$? — restarting in 2s\"; sleep 2; done 2>&1 | tee -a $APP_DIR/admin.log"

echo "pin-admin started (restart loop). logs: $APP_DIR/admin.log"
