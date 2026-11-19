#!/usr/bin/env bash
set -euo pipefail

# ECR Credential Provider setup for K3s
# Run on a K3s node after verified binary is supplied.
# Usage: sudo bash setup-ecr-provider.sh BINARY_PATH CONFIG_PATH

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: Run as root"
  exit 1
}

PLUGIN="${1:?ECR provider binary path required}"
CONFIG="${2:?Credential provider YAML path required}"
DEST="/var/lib/rancher/credentialprovider"

[[ -x "$PLUGIN" ]] || {
  echo "ERROR: Provider binary missing or not executable"
  exit 1
}

[[ -r "$CONFIG" ]] || {
  echo "ERROR: Provider configuration missing"
  exit 1
}

install -d -m 0755 "$DEST/bin"
install -m 0755 "$PLUGIN" "$DEST/bin/ecr-credential-provider"
install -m 0644 "$CONFIG" "$DEST/config.yaml"

echo "ECR credential provider files installed."
echo "Next: verify K3s startup and ECR image pull."
