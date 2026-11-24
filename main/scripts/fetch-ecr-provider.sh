#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${ECR_S3_BUCKET:?Approved S3 bucket required}"
: "${ECR_S3_KEY:?S3 object key required}"
: "${ECR_PROVIDER_SHA256:?SHA256 required}"

[[ "$ECR_PROVIDER_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
  echo "ERROR: Invalid SHA256" >&2
  exit 1
}

for cmd in aws sha256sum; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Missing $cmd" >&2
    exit 1
  }
done

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

aws s3 cp \
  "s3://${ECR_S3_BUCKET}/${ECR_S3_KEY}" \
  "$TMP" --only-show-errors >&2

printf '%s  %s\n' "$ECR_PROVIDER_SHA256" "$TMP" |
  sha256sum --check --status - || {
    echo "ERROR: ECR binary checksum mismatch" >&2
    exit 1
  }

install -d -m 0755 /opt/durian/bin
install -m 0755 "$TMP" /opt/durian/bin/ecr-credential-provider

printf '%s\n' /opt/durian/bin/ecr-credential-provider
