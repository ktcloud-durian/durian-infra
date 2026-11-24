#!/usr/bin/env bash
set -euo pipefail
umask 077

# Install Argo CD ONCE, on ONE healthy AWS K3s Master, after HA bootstrap.
# This script does NOT install K3s, and does NOT modify the original team install.sh.
[[ "${1:-}" == "--install" ]] || {
  echo 'Usage: DURIAN_GITOPS_APPROVED=yes ARGOCD_CHART_VERSION=<approved version> GITOPS_APP_PATH=apps/sample-app/overlays/aws-prod bash install-argocd-gitops.sh --install' >&2
  exit 2
}
[[ "$EUID" -eq 0 ]] || { echo 'Root required' >&2; exit 1; }
[[ "${DURIAN_GITOPS_APPROVED:-}" == "yes" ]] || { echo 'GitOps install not approved' >&2; exit 1; }
: "${ARGOCD_CHART_VERSION:?Pin a reviewed argo-cd Helm chart version}"
: "${GITOPS_APP_PATH:?Approved GitOps overlay path required}"

case "$GITOPS_APP_PATH" in
  apps/sample-app/overlays/aws-prod|apps/sample-app/overlays/staging|apps/sample-app/overlays/prod) ;;
  *) echo "Unapproved GitOps path: $GITOPS_APP_PATH" >&2; exit 1 ;;
esac

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
[[ -r "$KUBECONFIG" ]] || { echo 'K3s kubeconfig not found' >&2; exit 1; }
[[ -r /opt/durian/bootstrap/image-registry ]] || {
  echo 'Not an approved new AWS HA node; refusing to modify an existing team K3s cluster' >&2
  exit 1
}
command -v kubectl >/dev/null || { echo 'kubectl not available' >&2; exit 1; }
kubectl get --raw='/readyz' >/dev/null || { echo 'K3s API not ready' >&2; exit 1; }
# The new Terraform master installer assigns these unique node names.
mapfile -t AWS_MASTERS < <(kubectl get nodes -o name | grep -E '^node/durian-master-i-[a-f0-9]+$' || true)
if (( ${#AWS_MASTERS[@]} < 2 )); then
  echo 'Two AWS HA masters are not registered; Argo CD installation blocked' >&2
  exit 1
fi
for n in "${AWS_MASTERS[@]}"; do
  kubectl wait --for=condition=Ready "$n" --timeout=15s >/dev/null || {
    echo "Master is not Ready: $n" >&2; exit 1;
  }
done

# Avoid an accidental second Argo CD installation atop a non-Helm installation.
if kubectl -n argocd get deployment argocd-server >/dev/null 2>&1; then
  if ! command -v helm >/dev/null || ! helm -n argocd status argocd >/dev/null 2>&1; then
    echo 'Existing Argo CD is not recognized as the durian Helm release; review manually' >&2
    exit 1
  fi
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --wait --timeout 10m

# Namespaced GitOps Application, aimed explicitly at THIS AWS K3s cluster.
# Production defaults to manual Sync; staging remains automatic.
if [[ "$GITOPS_APP_PATH" == 'apps/sample-app/overlays/staging' ]]; then
  cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: durian-aws-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/ktcloud-durian/cicd-platform-gitops.git
    targetRevision: main
    path: apps/sample-app/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
else
  [[ "$GITOPS_APP_PATH" == 'apps/sample-app/overlays/aws-prod' ]] || {
    echo 'For AWS production, use aws-prod overlay rather than the shared prod overlay' >&2
    exit 1
  }
  cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: durian-aws-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/ktcloud-durian/cicd-platform-gitops.git
    targetRevision: main
    path: apps/sample-app/overlays/aws-prod
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
EOF
fi

echo 'Argo CD configured. Production requires approved manual Sync.'
