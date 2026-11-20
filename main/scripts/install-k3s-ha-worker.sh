#!/usr/bin/env bash
set -euo pipefail
umask 077

# DURIAN AWS K3s Worker - HA Bootstrap DRAFT
# Intended for AWS ASG workers.
# No installation without explicit approval.

if [[ "${1:-}" != "--install" ]]; then
  echo "DRAFT: Worker bootstrap not executed."
  exit 0
fi

[[ "${DURIAN_HA_APPROVED:-}" == "yes" ]] || {
  echo "ERROR: Deployment not approved."
  exit 1
}

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: root required."
  exit 1
}

: "${K3S_VERSION:?Pinned K3s version required}"

for cmd in aws curl; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Missing command: $cmd"
    exit 1
  }
done

if command -v k3s >/dev/null; then
  echo "ERROR: K3s already installed. Review manually."
  exit 1
fi

AWS_REGION="${AWS_REGION:-ap-northeast-2}"

ssm_get() {
  aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$1" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

# Registration endpoint must be an approved private DNS name or IP.
REGISTRATION=$(ssm_get /durian/k3s/ha/registration-endpoint)

[[ "$REGISTRATION" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || {
  echo "ERROR: Invalid registration endpoint."
  exit 1
}

# IMDSv2: unique node identity
IMDS_TOKEN=$(curl -fsS --max-time 10 -X PUT \
  http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')

INSTANCE_ID=$(curl -fsS --max-time 10 \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -fsS --max-time 10 \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

[[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]] || {
  echo "ERROR: Invalid EC2 instance ID."
  exit 1
}

[[ "$AZ" =~ ^[a-z0-9-]+$ ]] || {
  echo "ERROR: Invalid availability zone."
  exit 1
}

NODE_NAME="durian-worker-${INSTANCE_ID}"

# Store Agent Token in root-readable file only.
install -d -m 0700 /etc/rancher/k3s

TOKEN_FILE="/etc/rancher/k3s/agent-token"

ssm_get /durian/k3s/ha/agent-token > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

[[ -s "$TOKEN_FILE" ]] || {
  echo "ERROR: Agent Token is empty."
  exit 1
}

echo "Preparing K3s Worker: ${NODE_NAME}"
echo "AWS AZ: ${AZ}"
echo "Server: ${REGISTRATION}:6443"
echo "Agent Token is not printed."

ECR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${DURIAN_IMAGE_REGISTRY:-ecr}" == "ecr" ]]; then
# Install ECR credential provider before K3s starts.
# Fetch approved ECR artifact before K3s installation.
if [[ -z "${ECR_PROVIDER_BIN:-}" ]]; then
  ECR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  ECR_S3_BUCKET="$(cat "$ECR_DIR/ecr-s3-bucket")"
  ECR_S3_KEY="$(cat "$ECR_DIR/ecr-s3-key")"
  ECR_PROVIDER_SHA256="$(cat "$ECR_DIR/ecr-provider.sha256")"

  ECR_PROVIDER_BIN="$(
    ECR_S3_BUCKET="$ECR_S3_BUCKET" \
    ECR_S3_KEY="$ECR_S3_KEY" \
    ECR_PROVIDER_SHA256="$ECR_PROVIDER_SHA256" \
    bash "$ECR_DIR/fetch-ecr-provider.sh"
  )"
fi
: "${ECR_PROVIDER_BIN:?Verified ECR provider binary path required}"
: "${ECR_PROVIDER_SHA256:?Verified ECR provider SHA256 required}"

ECR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -x "$ECR_PROVIDER_BIN" ]] || {
  echo "ERROR: ECR provider binary missing."
  exit 1
}
printf '%s  %s\n' "$ECR_PROVIDER_SHA256" "$ECR_PROVIDER_BIN" |
  sha256sum --check --status - || {
    echo "ERROR: ECR binary checksum mismatch."
    exit 1
  }

bash "$ECR_DIR/setup-ecr-provider.sh" \
  "$ECR_PROVIDER_BIN" \
  "$ECR_DIR/ecr-credential-provider-config.yaml"
fi
INSTALLER=$(mktemp)
trap 'rm -f "$INSTALLER"' EXIT

curl -fsSL https://get.k3s.io -o "$INSTALLER"

INSTALL_K3S_VERSION="$K3S_VERSION" \
INSTALL_K3S_EXEC="agent --server https://${REGISTRATION}:6443 --token-file ${TOKEN_FILE} --node-name ${NODE_NAME} --node-label durian.io/az=${AZ}" \
sh "$INSTALLER"

systemctl is-active --quiet k3s-agent || {
  echo "ERROR: K3s Agent service is not active."
  exit 1
}

echo "K3s Agent service started."
echo "Verify node Ready status from the Master."
