#!/bin/bash
# k3s installation & setup script for Pin Backend (Idempotent)
set -e

# Verify if run as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo or as root:"
  echo "  sudo ./install_k3s.sh"
  exit 1
fi

ACTUAL_USER="${SUDO_USER:-$USER}"

echo "=== Installing/Updating k3s (Single-Node) ==="
# The official k3s installation script is idempotent and handles upgrades safely.
curl -sfL https://get.k3s.io | sh -

# Helper function to setup kubectl access for a user safely (idempotent)
setup_user_kubeconfig() {
  local target_user="$1"
  
  # Verify target user exists
  if ! id "$target_user" &>/dev/null; then
    echo "User '$target_user' does not exist. Skipping..."
    return
  fi
  
  local target_home
  target_home=$(eval echo "~$target_user")
  
  echo "Setting up kubectl config for user: $target_user"
  mkdir -p "$target_home/.kube"
  
  # Copy config safely and overwrite if exists
  cp /etc/rancher/k3s/k3s.yaml "$target_home/.kube/config"
  chown -R "$target_user:$(id -gn $target_user)" "$target_home/.kube"
  chmod 600 "$target_home/.kube/config"
  
  # Append environment variable to .bashrc only if not already present
  local bash_rc="$target_home/.bashrc"
  if [ -f "$bash_rc" ]; then
    if ! grep -q "export KUBECONFIG=" "$bash_rc"; then
      echo "export KUBECONFIG=\$HOME/.kube/config" >> "$bash_rc"
      echo "Added KUBECONFIG environment variable to $bash_rc"
    fi
  fi
}

echo "=== Configuring kubeconfig permissions ==="
# 1. Configure access for the user who ran the script via sudo
if [ "$ACTUAL_USER" != "root" ]; then
  setup_user_kubeconfig "$ACTUAL_USER"
fi

# 2. Configure access for any additional users passed as arguments (e.g. sudo ./install_k3s.sh user1 user2)
for extra_user in "$@"; do
  setup_user_kubeconfig "$extra_user"
done

# Wait for k3s cluster to be initialized
echo "Waiting for k3s to be ready..."
sleep 5

# Set KUBECONFIG for the current session to proceed
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

echo "=== Creating/Verifying namespace 'pin' ==="
# Dry-run + apply makes namespace creation idempotent (safe if namespace already exists)
kubectl create namespace pin --dry-run=client -o yaml | kubectl apply -f -

echo "=== k3s Installation & Setup Completed Successfully ==="
kubectl get nodes
