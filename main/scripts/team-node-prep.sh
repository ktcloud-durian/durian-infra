#!/usr/bin/env bash
set -euo pipefail
umask 077

# Reuses the preparation concepts from the team's original scripts/install.sh.
# This is a separate helper: NEVER source the original install.sh, which executes ROLE at EOF.
[[ "${1:-}" == "--prepare" ]] || { echo "Usage: team-node-prep.sh --prepare master|worker" >&2; exit 2; }
ROLE="${2:-}"
[[ "$ROLE" == "master" || "$ROLE" == "worker" ]] || { echo "Invalid role" >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || { echo "Root required" >&2; exit 1; }
[[ "${DURIAN_TEAM_PREP_APPROVED:-}" == "yes" ]] || { echo "Team preparation not approved" >&2; exit 1; }

REGION="${AWS_REGION:-ap-northeast-2}"
export AWS_DEFAULT_REGION="$REGION"

echo "[DURIAN] Common packages / time sync / exporter ($ROLE)"
timedatectl set-timezone Asia/Seoul
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl unzip jq chrony prometheus-node-exporter
install -d -m 0755 /etc/chrony/sources.d
printf '%s\n' 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' \
  > /etc/chrony/sources.d/durian-aws.sources
systemctl enable --now chrony prometheus-node-exporter
systemctl restart chrony

# The AWS K3s Masters need an approved route to their external datastore.
# Workers do NOT have to join Tailscale just to connect to Masters in the AWS VPC.
if [[ "$ROLE" == "master" || "${DURIAN_TAILSCALE_ON_WORKER:-false}" == "true" ]]; then
  echo "[DURIAN] Tailscale setup ($ROLE)"
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled

  if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
    echo "[DURIAN] Tailscale already connected"
  else
    # Same parameter path as the original team install.sh.
    # Do not print the key. VPN routes and ACL must be approved by NetworkOps.
    TS_AUTH_KEY="$(aws ssm get-parameter \
      --region "$REGION" \
      --name /durian/tailscale/oauth \
      --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
    if [[ -z "$TS_AUTH_KEY" || "$TS_AUTH_KEY" == "None" ]]; then
      echo "[DURIAN] Tailscale auth not available: finish VPN setup with the team" >&2
    else
      tailscale up \
        --authkey="$TS_AUTH_KEY" \
        --advertise-tags="${DURIAN_TS_TAG:-tag:durian-node}" \
        --hostname="durian-aws-${ROLE}-$(hostname -s)"
      unset TS_AUTH_KEY
    fi
  fi
fi

echo "[DURIAN] Common preparation done; K3s installation is handled separately"
