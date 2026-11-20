#!/usr/bin/env bash
set -euo pipefail
umask 077

# DURIAN AWS HA K3s bootstrap. Execution is opt-in from approved User Data.
[[ "${1:-}" == '--install' ]] || exit 0
ROLE="${2:-}"
[[ "$ROLE" == 'master' || "$ROLE" == 'worker' ]] || { echo 'Invalid role' >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || { echo 'Root required' >&2; exit 1; }

DIR=/opt/durian/bootstrap
REGION="${AWS_REGION:-ap-northeast-2}"
for f in k3s-version image-registry team-node-prep.sh; do
  [[ -s "$DIR/$f" ]] || { echo "Bootstrap file missing: $f" >&2; exit 1; }
done

export K3S_VERSION="$(cat "$DIR/k3s-version")"
export DURIAN_IMAGE_REGISTRY="$(cat "$DIR/image-registry")"
[[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || {
  echo 'K3s version must be pinned (vX.Y.Z+k3sN)' >&2; exit 1;
}
case "$DURIAN_IMAGE_REGISTRY" in ghcr|ecr) ;; *) echo 'Invalid image registry' >&2; exit 1;; esac

# AWS CLI is needed to check IAM and secure SSM parameters.
if ! command -v aws >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip
  TMPDIR_AWS="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_AWS"' EXIT
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
    -o "$TMPDIR_AWS/awscliv2.zip"
  ( cd "$TMPDIR_AWS" && unzip -q awscliv2.zip && ./aws/install )
fi
export AWS_DEFAULT_REGION="$REGION"
aws sts get-caller-identity >/dev/null

if [[ "$DURIAN_IMAGE_REGISTRY" == 'ecr' ]]; then
  for f in ecr-s3-bucket ecr-s3-key ecr-provider.sha256; do
    [[ -s "$DIR/$f" ]] || { echo "ECR artifact data missing: $f" >&2; exit 1; }
  done
  export ECR_S3_BUCKET="$(cat "$DIR/ecr-s3-bucket")"
  export ECR_S3_KEY="$(cat "$DIR/ecr-s3-key")"
  export ECR_PROVIDER_SHA256="$(cat "$DIR/ecr-provider.sha256")"
  aws s3api head-object --bucket "$ECR_S3_BUCKET" --key "$ECR_S3_KEY" >/dev/null
fi

if [[ "$ROLE" == 'master' ]]; then
  PARAMS=(
    /durian/k3s/ha/server-token
    /durian/k3s/ha/agent-token
    /durian/k3s/ha/datastore-endpoint
    /durian/k3s/ha/registration-endpoint
  )
else
  PARAMS=(
    /durian/k3s/ha/agent-token
    /durian/k3s/ha/registration-endpoint
  )
fi
for p in "${PARAMS[@]}"; do
  aws ssm get-parameter --name "$p" --query Parameter.Name --output text >/dev/null
done

# Team common setup (chrony, exporter, Tailscale). Does NOT install K3s.
export DURIAN_TEAM_PREP_APPROVED=yes
bash "$DIR/team-node-prep.sh" --prepare "$ROLE"

if [[ "$ROLE" == 'master' ]]; then
  command -v tailscale >/dev/null || { echo 'Tailscale unavailable' >&2; exit 1; }
  tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null || {
    echo 'Tailscale not connected. Check approved route to external HA datastore' >&2
    exit 1
  }
  export K3S_DATASTORE_CAFILE=/etc/durian/pki/mariadb-ca.pem
  [[ -r "$K3S_DATASTORE_CAFILE" ]] || {
    echo 'External HA datastore CA missing' >&2; exit 1
  }
fi

# No team/ArgoCD install.sh sourcing: it would install a second K3s.
export DURIAN_HA_APPROVED=yes
exec bash "$DIR/install-k3s-ha-$ROLE.sh" --install
