#!/usr/bin/env bash
# durian 서버 설치 스크립트 (ROLE=master | worker | monitor). 재실행 가능.
# 사용: sudo ROLE=master ./install.sh
# 비밀번호/토큰/키는 이 파일에 넣지 않는다. SSM Parameter Store(/durian/...)에서 읽는다.
set -euo pipefail

ROLE="${ROLE:?ROLE=master|worker|monitor 를 지정하세요}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
TZ_NAME="${TZ_NAME:-Asia/Seoul}"
SSM_PREFIX="${SSM_PREFIX:-/durian}"
CLUSTER="${CLUSTER:-}"                       # 예: a | c. 지정하면 클러스터별 SSM 경로(/durian/k3s/<CLUSTER>/...) 사용
K3S_SSM="$SSM_PREFIX/k3s${CLUSTER:+/$CLUSTER}"

[[ $EUID -ne 0 ]] && { echo "root(sudo)로 실행하세요"; exit 1; }
case "$ROLE" in master|worker|monitor) ;; *) echo "ROLE은 master|worker|monitor"; exit 1 ;; esac
export AWS_DEFAULT_REGION="$AWS_REGION"
exec > >(tee -a /var/log/durian-install.log) 2>&1

### ---------- 공용 함수 ----------
imds() { # EC2 메타데이터(IMDSv2)
  local t
  t=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 0
  curl -sf -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1" || true
}
ssm_get() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text 2>/dev/null || true; }
ssm_put() { # ssm_put 이름 값 [String|SecureString]
  aws ssm put-parameter --name "$1" --value "$2" --type "${3:-String}" --overwrite >/dev/null 2>&1 \
    || { echo "ERROR: SSM write failed; check EC2 IAM profile and ssm:PutParameter" >&2; return 1; }
}
install_awscli() {
  command -v aws >/dev/null && return
  local arch; arch=$(uname -m)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
}
tailscale_setup() {
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  tailscale status >/dev/null 2>&1 && return          # 이미 로그인됨
  local key; key=$(ssm_get "$SSM_PREFIX/tailscale/${TS_KEY_NAME:-aws-${ROLE}}")
  if [[ -z "$key" ]]; then
    echo "  Tailscale 키($SSM_PREFIX/tailscale/${TS_KEY_NAME:-aws-${ROLE}}) 없음 → 건너뜀. 나중에 tailscale up 실행"
    return
  fi
  # tskey-client-*(OAuth)만 ?ephemeral/preauthorized 옵션을 붙인다. tskey-auth-*는 키 자체에 옵션이 들어 있음
  [[ "$key" == tskey-client-* ]] && key="${key}?ephemeral=${TS_EPHEMERAL:-$([[ $ROLE == worker ]] && echo true || echo false)}&preauthorized=true"
  local args=("--authkey=${key}"
              "--advertise-tags=${TS_TAG:-tag:durian-${ROLE}}" --ssh "--hostname=${NODE_NAME}")
  if [[ -n "${TS_ROUTES:-}" ]]; then                  # 서브넷 라우터 (예: 10.20.0.0/16)
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-tailscale.conf && sysctl -p /etc/sysctl.d/99-tailscale.conf
    args+=("--advertise-routes=${TS_ROUTES}")
  fi
  tailscale up "${args[@]}"
}

common() {
  echo "[common] 시간대($TZ_NAME) / 패키지 / Tailscale"
  timedatectl set-timezone "$TZ_NAME"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl unzip jq chrony prometheus-node-exporter
  mkdir -p /etc/chrony/sources.d
  echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' > /etc/chrony/sources.d/aws.sources
  systemctl enable chrony prometheus-node-exporter
  systemctl restart chrony
  systemctl start prometheus-node-exporter
  install_awscli
  tailscale_setup
}

### ---------- master ----------
master() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  local pip; pip=$(imds local-ipv4)

  echo "[master 1/5] K3s"
  mkdir -p /var/lib/rancher/k3s/server/manifests
  cat > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml <<'EOF'
# ALB 타깃 그룹이 가리킬 NodePort (HTTP 30080 / HTTPS 30443)
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      spec:
        type: NodePort
    ports:
      web:
        nodePort: 30080
      websecure:
        nodePort: 30443
EOF
  if ! command -v k3s >/dev/null; then
    local ex="server --write-kubeconfig-mode 600 --node-name ${NODE_NAME} --tls-san ${pip}"
    [[ -n "${MASTER_TLS_SAN:-}" ]] && ex+=" --tls-san ${MASTER_TLS_SAN}"
    [[ -n "${CLUSTER_CIDR:-}" ]] && ex+=" --cluster-cidr ${CLUSTER_CIDR}"   # 예: 10.52.0.0/16 (허용 포트 목록 2번)
    [[ -n "${SERVICE_CIDR:-}" ]] && ex+=" --service-cidr ${SERVICE_CIDR}"   # 예: 10.53.0.0/16
    [[ "${SECRETS_ENCRYPTION:-false}" == "true" ]] && ex+=" --secrets-encryption"   # SRV-04
    [[ "${MASTER_TAINT:-false}" == "true" ]] && ex+=" --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION:-}" \
      INSTALL_K3S_CHANNEL="${K3S_CHANNEL:-stable}" INSTALL_K3S_EXEC="$ex" sh -
  fi
  local n=0
  until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
    sleep 3; n=$((n+1)); (( n > 200 )) && { echo "K3s Ready 대기 시간 초과"; exit 1; }
  done

  echo "[master 2/5] worker 조인 정보를 SSM에 저장"
  ssm_put "$K3S_SSM/token" "$(cat /var/lib/rancher/k3s/server/node-token)" SecureString
  ssm_put "$K3S_SSM/master-ip" "$pip"

  echo "[master 3/5] Helm"
  command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  echo "[master 4/5] Argo CD"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1 && ! helm -n argocd status argocd >/dev/null 2>&1; then
    echo "  기존 Argo CD(kubectl apply로 설치됨) 발견 → Helm 설치 건너뜀"
  else
    helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
      ${ARGOCD_CHART_VERSION:+--version "$ARGOCD_CHART_VERSION"} --wait --timeout 10m
  fi
  if [[ -n "${GITOPS_APP_PATH:-}" ]]; then            # 예: apps/sample-app/overlays/staging
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${GITOPS_APP_NAME:-sample-app}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL:-https://github.com/ktcloud-durian/cicd-platform-gitops.git}
    targetRevision: main
    path: ${GITOPS_APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${GITOPS_APP_NAMESPACE:-default}
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
EOF
  fi

  echo "[master 5/5] 선택 항목 (kube-state-metrics / Velero)"
  if [[ "${ENABLE_KSM:-true}" == "true" ]]; then      # Monitor EC2가 <master-ip>:30081 로 수집
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
    helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
      -n monitoring --create-namespace --set service.type=NodePort --set service.nodePort=30081
  fi
  if [[ -n "${VELERO_BUCKET:-}" ]]; then              # 서버 IAM 역할에 S3 권한 필요 (Access Key 사용 안 함)
    helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update >/dev/null
    helm upgrade --install velero vmware-tanzu/velero -n velero --create-namespace \
      --set configuration.backupStorageLocation[0].name=default \
      --set configuration.backupStorageLocation[0].provider=aws \
      --set configuration.backupStorageLocation[0].bucket="$VELERO_BUCKET" \
      --set configuration.backupStorageLocation[0].config.region="$AWS_REGION" \
      --set configuration.volumeSnapshotLocation[0].name=default \
      --set configuration.volumeSnapshotLocation[0].provider=aws \
      --set configuration.volumeSnapshotLocation[0].config.region="$AWS_REGION" \
      --set credentials.useSecret=false \
      --set initContainers[0].name=velero-plugin-for-aws \
      --set initContainers[0].image="velero/velero-plugin-for-aws:${VELERO_AWS_PLUGIN:-v1.10.0}" \
      --set initContainers[0].volumeMounts[0].mountPath=/target \
      --set initContainers[0].volumeMounts[0].name=plugins
  fi
  echo "Argo CD admin 비밀번호 확인(화면에 출력하지 않음):"
  echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

### ---------- worker ----------
worker() {
  local ip token az n=0
  # master가 SSM에 token/master-ip를 쓸 때까지 최대 약 15분 재시도 (MASTER_IP/K3S_TOKEN 직접 지정 시 즉시 사용)
  ip="${MASTER_IP:-}"; token="${K3S_TOKEN:-}"
  until [[ -n "$ip" && -n "$token" ]]; do
    [[ -z "${MASTER_IP:-}" ]] && ip=$(ssm_get "$K3S_SSM/master-ip")
    [[ -z "${K3S_TOKEN:-}" ]] && token=$(ssm_get "$K3S_SSM/token")
    [[ -n "$ip" && -n "$token" ]] && break
    n=$((n+1)); (( n > 90 )) && { echo "master IP/토큰을 SSM($K3S_SSM/*)에서 찾지 못함. master를 먼저 설치하세요"; exit 1; }
    sleep 10
  done
  n=0
  echo "[worker] master(${ip}) 대기"
  until curl -ksf "https://${ip}:6443/cacerts" >/dev/null; do
    sleep 5; n=$((n+1)); (( n > 120 )) && { echo "master 접속 시간 초과(SG 6443 확인)"; exit 1; }
  done
  if ! command -v k3s >/dev/null; then
    az=$(imds placement/availability-zone)
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION:-}" \
      INSTALL_K3S_CHANNEL="${K3S_CHANNEL:-stable}" \
      K3S_URL="https://${ip}:6443" K3S_TOKEN="$token" \
      INSTALL_K3S_EXEC="agent --node-name ${NODE_NAME} --node-label topology.kubernetes.io/zone=${az}" sh -
  fi
  echo "[worker] 조인 완료. master에서 확인: kubectl get nodes"
}

### ---------- monitor ----------
monitor() {
  local base=/opt/monitoring mip pip dw gpw
  pip=$(imds local-ipv4)
  mip=$(ssm_get "$K3S_SSM/master-ip")
  echo "[monitor 1/3] Docker"
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
  systemctl enable --now docker

  echo "[monitor 2/3] 설정 파일 생성 ($base)"
  mkdir -p $base/{targets,rules,secrets,grafana/provisioning/datasources}
  cat > $base/prometheus.yml <<'EOF'
global:
  scrape_interval: 30s
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
rule_files:
  - /etc/prometheus/rules/*.yml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
  - job_name: node
    file_sd_configs:
      - files: ['/etc/prometheus/targets/node-*.json']
  - job_name: kube-state-metrics
    file_sd_configs:
      - files: ['/etc/prometheus/targets/ksm-*.json']
EOF
  cat > $base/rules/basic.yml <<'EOF'
groups:
  - name: basic
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels: { severity: critical }
        annotations: { summary: "{{ $labels.job }} {{ $labels.instance }} 응답 없음" }
      - alert: DiskAlmostFull
        expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes) < 0.15
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }} 디스크 85% 이상 사용" }
      - alert: MemoryHigh
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.10
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }} 메모리 90% 이상 사용" }
EOF
  # 수집 대상 (워커/온프레미스는 targets/node-*.json 파일을 추가하면 자동 반영)
  local nodes="\"${pip}:9100\""
  [[ -n "$mip" ]] && nodes+=",\"${mip}:9100\""
  echo "[{\"targets\":[${nodes}],\"labels\":{\"cluster\":\"aws\"}}]" > $base/targets/node-aws.json
  [[ -n "$mip" ]] && echo "[{\"targets\":[\"${mip}:30081\"],\"labels\":{\"cluster\":\"aws\"}}]" > $base/targets/ksm-aws.json

  dw=$(ssm_get "$SSM_PREFIX/discord/webhook")
  if [[ -n "$dw" ]]; then
    printf '%s' "$dw" > $base/secrets/discord_webhook
    chown 65534:65534 $base/secrets/discord_webhook && chmod 600 $base/secrets/discord_webhook
    cat > $base/alertmanager.yml <<'EOF'
route:
  receiver: discord
  group_by: [alertname, instance]
receivers:
  - name: discord
    discord_configs:
      - webhook_url_file: /etc/alertmanager/secrets/discord_webhook
        send_resolved: true
EOF
  else
    echo "  Discord 웹훅($SSM_PREFIX/discord/webhook) 없음 → 알림 전송 없이 설치"
    printf 'route:\n  receiver: none\nreceivers:\n  - name: none\n' > $base/alertmanager.yml
  fi

  cat > $base/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
EOF
  gpw=$(ssm_get "$SSM_PREFIX/grafana/admin-password")
  if [[ -z "$gpw" ]]; then
    gpw=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    echo "$gpw" > /root/grafana-admin-password && chmod 600 /root/grafana-admin-password
    echo "  Grafana 비밀번호를 생성해 /root/grafana-admin-password 에 저장함"
  fi
  cat > $base/.env <<EOF
TZ=${TZ_NAME}
GF_SECURITY_ADMIN_PASSWORD=${gpw}
PROMETHEUS_TAG=${PROMETHEUS_TAG:-latest}
ALERTMANAGER_TAG=${ALERTMANAGER_TAG:-latest}
GRAFANA_TAG=${GRAFANA_TAG:-latest}
EOF
  chmod 600 $base/.env
  cat > $base/docker-compose.yml <<'EOF'
services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_TAG}
    restart: unless-stopped
    environment: [TZ]
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=15d"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
      - ./targets:/etc/prometheus/targets:ro
      - prom-data:/prometheus
    ports: ["9090:9090"]
  alertmanager:
    image: prom/alertmanager:${ALERTMANAGER_TAG}
    restart: unless-stopped
    environment: [TZ]
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - ./secrets:/etc/alertmanager/secrets:ro
      - am-data:/alertmanager
    ports: ["9093:9093"]
  grafana:
    image: grafana/grafana:${GRAFANA_TAG}
    restart: unless-stopped
    environment: [TZ, GF_SECURITY_ADMIN_PASSWORD]
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana-data:/var/lib/grafana
    ports: ["3000:3000"]
volumes:
  prom-data:
  am-data:
  grafana-data:
EOF

  echo "[monitor 3/3] 기동"
  (cd $base && docker compose up -d)
  echo "Grafana http://${pip}:3000 (admin) / Prometheus :9090 / Alertmanager :9093"
}

### ---------- 실행 ----------
case "$ROLE" in
  master)  NODE_NAME="${NODE_NAME:-durian-master}" ;;
  worker)  NODE_NAME="${NODE_NAME:-durian-worker-$(imds instance-id)}" ;;
  monitor) NODE_NAME="${NODE_NAME:-durian-monitor}" ;;
esac
common
"$ROLE"
echo "=== 설치 완료 (ROLE=$ROLE) ==="
