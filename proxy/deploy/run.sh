#!/usr/bin/env bash
# Start the ปิ่น LLM proxy in a detached tmux session with a restart loop, so it
# survives crashes (on-device chat depends on it). No root.
#   deploy/run.sh [app-dir]
set -euo pipefail

APP_DIR="${1:-${APP_DIR:-$HOME/pin-proxy}}"
export PATH="$HOME/.local/bin:$PATH"
cd "$APP_DIR"

tmux kill-session -t pin-proxy 2>/dev/null || true
tmux new-session -d -s pin-proxy \
  "while true; do echo \"[proxy] starting \$(date)\"; uv run pin-proxy; echo \"[proxy] exited rc=\$? — restarting in 2s\"; sleep 2; done 2>&1 | tee -a $APP_DIR/proxy.log"

echo "pin-proxy started (restart loop). logs: $APP_DIR/proxy.log"
