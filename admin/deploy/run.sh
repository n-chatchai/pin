#!/usr/bin/env bash
# (Re)start the ปิ่น admin backoffice via systemd --user. Unit pin-admin.service
# (Restart=always, port 8800) owns the restart loop + reboot survival. Needs the
# `proxy` dir as a sibling (~/pin/proxy, editable path dep). Run ON the VPS.
#   deploy/run.sh
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

systemctl --user restart pin-admin
systemctl --user is-active pin-admin
echo "pin-admin (re)started. logs: journalctl --user -u pin-admin -f"
