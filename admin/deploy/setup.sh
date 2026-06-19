#!/usr/bin/env bash
# Run ON the VPS: build the admin venv with uv. The `proxy` dir must sit as a
# sibling of this app-dir (pin-admin depends on pin-proxy via an editable path).
#   deploy/setup.sh [app-dir]
set -euo pipefail

APP_DIR="${1:-${APP_DIR:-$HOME/pin-admin}}"
export PATH="$HOME/.local/bin:$PATH"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found — installing to ~/.local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

cd "$APP_DIR"
uv sync                      # fastapi, jinja2, httpx, cryptography, + pin-proxy (../proxy)
echo "pin-admin venv ready in $APP_DIR"
