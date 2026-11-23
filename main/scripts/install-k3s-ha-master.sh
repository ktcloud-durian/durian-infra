#!/usr/bin/env bash
set -euo pipefail
umask 077

# Retired by PR9 independent-cluster migration: the external-DB HA flow is unsupported.
# Use scripts/install.sh with ROLE=master and CLUSTER=a or c instead.
if [[ "${1:-}" == "--install" ]]; then
  echo "ERROR: legacy external-DB HA installer retired (PR9/PR10); use scripts/install.sh" >&2
  exit 1
fi

# DURIAN AWS K3s HA Master - DRAFT
# External MariaDB datastore on OpenStack.
# Never run until team security/network approval.

if [[ "${1:-}" != "--install" ]]; then
  echo "Draft mode: no installation performed."
  exit 0
fi

[[ "${DURIAN_HA_APPROVED:-}" == "yes" ]] || {
  echo "ERROR: HA deployment not approved."
  exit 1
}

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: root required."
  exit 1
}

: "${K3S_VERSION:?Pinned K3s version required}"
: "${K3S_DATASTORE_CAFILE:?Verified DB CA file required}"

[[ -r "$K3S_DATASTORE_CAFILE" ]] || {
  echo "ERROR: DB CA file missing."
  exit 1
}

for cmd in aws curl; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd missing."
    exit 1
  }
done

if command -v k3s >/dev/null; then
  echo "ERROR: K3s already installed. Review manually."
  exit 1
fi

ssm_get() {
  aws ssm get-parameter \
    --region ap-northeast-2 \
    --name "$1" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

SERVER_TOKEN=$(ssm_get /durian/k3s/ha/server-token)
AGENT_TOKEN=$(ssm_get /durian/k3s/ha/agent-token)
DATASTORE=$(ssm_get /durian/k3s/ha/datastore-endpoint)
REGISTRATION=$(ssm_get /durian/k3s/ha/registration-endpoint)

[[ -n "$SERVER_TOKEN" && -n "$AGENT_TOKEN" &&
   "$DATASTORE" == mysql://* &&
   "$REGISTRATION" =~ ^[A-Za-z0-9.-]+$ ]] || {
  echo "ERROR: Invalid HA configuration."
  exit 1
}

# Unique node identity via IMDSv2.
IMDS_TOKEN=$(curl -fsS -X PUT \
  http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')

INSTANCE_ID=$(curl -fsS \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

NODE_NAME="durian-master-${INSTANCE_ID}"

echo "Starting K3s HA master: ${NODE_NAME}"
echo "Secrets are not printed."

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
# Stage bundled Traefik NodePort config before K3s server starts.
install -d -m 0755 /var/lib/rancher/k3s/server/manifests
install -m 0644 "$ECR_DIR/traefik-config.yaml" /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
INSTALLER=$(mktemp)
trap 'rm -f "$INSTALLER"' EXIT
curl -fsSL https://get.k3s.io -o "$INSTALLER"

K3S_TOKEN="$SERVER_TOKEN" \
K3S_AGENT_TOKEN="$AGENT_TOKEN" \
K3S_DATASTORE_ENDPOINT="$DATASTORE" \
K3S_DATASTORE_CAFILE="$K3S_DATASTORE_CAFILE" \
INSTALL_K3S_VERSION="$K3S_VERSION" \
INSTALL_K3S_EXEC="server --node-name ${NODE_NAME} --tls-san ${REGISTRATION} --cluster-cidr 10.52.0.0/16 --service-cidr 10.53.0.0/16 --write-kubeconfig-mode 600" \
sh "$INSTALLER"

echo "K3s installation command completed."
