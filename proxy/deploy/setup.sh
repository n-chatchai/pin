#!/usr/bin/env bash
# Run ON the VPS (called by deploy.sh): build the proxy venv with uv. No root —
# uv manages its own Python. Only system need is a recent libc (httpx/argon2
# wheels are prebuilt). Usage:  deploy/setup.sh [app-dir]
set -euo pipefail

APP_DIR="${1:-${APP_DIR:-$HOME/pin-proxy}}"
export PATH="$HOME/.local/bin:$PATH"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found — installing to ~/.local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

cd "$APP_DIR"
uv sync                      # install deps from pyproject (fastapi, jinja2, argon2-cffi, …)
echo "pin-proxy venv ready in $APP_DIR"
