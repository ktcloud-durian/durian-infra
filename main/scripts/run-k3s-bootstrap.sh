#!/usr/bin/env bash
set -euo pipefail
umask 077

# DURIAN K3s bootstrap orchestrator
# Executes only after Terraform deployment approval.

[[ "${1:-}" == "--install" ]] || exit 0
ROLE="${2:-}"

[[ "$ROLE" == "master" || "$ROLE" == "worker" ]] || {
  echo "ERROR: Invalid role" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: Root required" >&2
  exit 1
}

DIR=/opt/durian/bootstrap
REGION=ap-northeast-2

for f in k3s-version ecr-s3-bucket ecr-s3-key ecr-provider.sha256; do
  [[ -s "$DIR/$f" ]] || {
    echo "ERROR: Missing bootstrap file: $f" >&2
    exit 1
  }
done

export K3S_VERSION="$(cat "$DIR/k3s-version")"
export ECR_S3_BUCKET="$(cat "$DIR/ecr-s3-bucket")"
export ECR_S3_KEY="$(cat "$DIR/ecr-s3-key")"
export ECR_PROVIDER_SHA256="$(cat "$DIR/ecr-provider.sha256")"

[[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || {
  echo "ERROR: Invalid K3s version" >&2
  exit 1
}

# Install AWS CLI v2 when unavailable.
if ! command -v aws >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl unzip

  TMPDIR_AWS=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_AWS"' EXIT

  curl -fsSL \
    https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
    -o "$TMPDIR_AWS/awscliv2.zip"

  (
    cd "$TMPDIR_AWS"
    unzip -q awscliv2.zip
    ./aws/install
  )
fi

export AWS_DEFAULT_REGION="$REGION"

# Check instance role and required S3 object.
aws sts get-caller-identity >/dev/null

aws s3api head-object \
  --bucket "$ECR_S3_BUCKET" \
  --key "$ECR_S3_KEY" >/dev/null

# Check SSM parameters without printing values.
if [[ "$ROLE" == "master" ]]; then
  PARAMS=(
    /durian/k3s/ha/server-token
    /durian/k3s/ha/agent-token
    /durian/k3s/ha/datastore-endpoint
    /durian/k3s/ha/registration-endpoint
  )

  # External datastore requires working Tailscale and trusted DB CA.
  command -v tailscale >/dev/null || {
    echo "ERROR: Tailscale not installed" >&2
    exit 1
  }
  tailscale status >/dev/null || {
    echo "ERROR: Tailscale not connected" >&2
    exit 1
  }

  export K3S_DATASTORE_CAFILE=/etc/durian/pki/mariadb-ca.pem
  [[ -r "$K3S_DATASTORE_CAFILE" ]] || {
    echo "ERROR: MariaDB CA certificate missing" >&2
    exit 1
  }
else
  PARAMS=(
    /durian/k3s/ha/agent-token
    /durian/k3s/ha/registration-endpoint
  )
fi

for p in "${PARAMS[@]}"; do
  aws ssm get-parameter --name "$p" \
    --query 'Parameter.Name' --output text >/dev/null
done

echo "Bootstrap prerequisites verified for $ROLE"

export DURIAN_HA_APPROVED=yes

exec bash "$DIR/install-k3s-ha-$ROLE.sh" --install
