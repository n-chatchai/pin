#!/usr/bin/env bash
# (Re)start the ปิ่น LLM proxy via systemd --user. The unit (pin-proxy.service,
# Restart=always) owns the crash-restart loop and survives reboot (linger on).
# Run ON the VPS. No root. App dir is ~/pin/proxy (matches the unit's
# WorkingDirectory) — not parameterised; the unit is.
#   deploy/run.sh
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

systemctl --user restart pin-proxy
systemctl --user is-active pin-proxy
echo "pin-proxy (re)started. logs: journalctl --user -u pin-proxy -f"
