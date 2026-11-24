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
              "--advertise-tags=${TS_TAG:-tag:durian-${ROLE}}" "--hostname=${NODE_NAME}")
  # NET-04: AWS access via SSM. Tailscale SSH disabled by default.
  [[ "${TS_SSH:-false}" == "true" ]] && args+=(--ssh)
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
# EX-09: K3s-managed Traefik HelmChartConfig must be in kube-system.
# V.1 security exception; review 2026-12-04. Not a Trivy scanner suppression in shell.
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
# Prometheus + Alertmanager + Grafana (Docker Compose, /opt/monitoring). 재실행 가능.
# - 3000/9090/9093은 127.0.0.1에만 바인딩. 접속은 SSM 포트 포워딩 (NET-06)
# - 웹훅/Grafana 비밀번호는 SSM SecureString에서 읽어 secrets/ 파일로만 전달. 화면/로그 출력 금지 (SEC-01·05)
# - 설정 반영은 docker kill -s HUP (--web.enable-lifecycle 사용 안 함)
# - 수집: Node Exporter만 (AWS=ec2_sd_configs 태그 필터, 온프렘=targets/onprem.json)
# 변수: NODE_TAG_KEY(기본 Role) NODE_TAG_VALUES(기본 master,worker, 쉼표 구분)
#       PROMETHEUS_TAG / ALERTMANAGER_TAG / GRAFANA_TAG / DASH_NODE_FULL_REV / DASH_NODE_FULL_SHA256
monitor() {
  local base=/opt/monitoring
  local prom_tag="${PROMETHEUS_TAG:-v3.5.0}" am_tag="${ALERTMANAGER_TAG:-v0.28.1}" gf_tag="${GRAFANA_TAG:-12.0.2}"
  local tag_key="${NODE_TAG_KEY:-Role}" tag_values="${NODE_TAG_VALUES:-master,worker}"
  local dash_rev="${DASH_NODE_FULL_REV:-46}"
  local dash_sha="${DASH_NODE_FULL_SHA256:-e58ddc5dc535d4c901f94da9648bc3e3d5ae7b6f78e98e185bce8b289961cea3}"
  local dw gpw tagvals v url n re='[^A-Za-z0-9,._:/+=@-]'
  local -a vals

  echo "[monitor 1/6] 사전 확인 (SSM 비밀값, 변수)"
  gpw=$(ssm_get "$SSM_PREFIX/grafana/admin-password")
  if [[ -z "$gpw" ]]; then
    echo "ERROR: Grafana 비밀번호($SSM_PREFIX/grafana/admin-password)가 SSM에 없거나 읽을 권한 없음 → 설치 중단" >&2
    exit 1
  fi
  dw=$(ssm_get "$SSM_PREFIX/discord/webhook")
  if [[ "$tag_key$tag_values" =~ $re ]]; then
    echo "ERROR: NODE_TAG_KEY/NODE_TAG_VALUES에 허용되지 않는 문자 (영문, 숫자, , . _ : / + = @ - 만)" >&2
    exit 1
  fi
  IFS=',' read -ra vals <<< "$tag_values"
  tagvals=""
  for v in "${vals[@]}"; do tagvals+="\"$v\", "; done
  tagvals="[${tagvals%, }]"

  echo "[monitor 2/6] Docker"
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
  systemctl enable --now docker

  echo "[monitor 3/6] 설정 파일 생성 ($base)"
  mkdir -p $base/{targets,rules,secrets,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/dashboards,grafana/cache}
  chmod 700 $base/secrets
  rm -f $base/targets/node-*.json $base/targets/ksm-*.json   # 이전 버전(고정 IP, kube-state-metrics) 파일 정리

  cat > $base/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
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
  # Monitor EC2 자신 (호스트의 Node Exporter)
  - job_name: node-monitor
    static_configs:
      - targets: ['host.docker.internal:9100']
        labels: { site: aws, name: ${NODE_NAME} }
  # AWS 노드: EC2 태그로 자동 발견 (인스턴스 역할 + IMDSv2 hop limit 2 필요)
  - job_name: node-aws
    ec2_sd_configs:
      - region: ${AWS_REGION}
        port: 9100
        refresh_interval: 60s
        filters:
          - name: tag:${tag_key}
            values: ${tagvals}
          - name: instance-state-name
            values: ["running"]
    relabel_configs:
      - target_label: site
        replacement: aws
      - source_labels: [__meta_ec2_tag_Cluster]
        target_label: cluster
      - source_labels: [__meta_ec2_tag_Name]
        target_label: name
  # 온프렘 노드: targets/onprem.json 이 있을 때만 수집 (없으면 대상 0개)
  - job_name: node-onprem
    file_sd_configs:
      - files: ['/etc/prometheus/targets/onprem.json']
    relabel_configs:
      - target_label: site
        replacement: onprem
EOF

  cat > $base/rules/basic.yml <<'EOF'
groups:
  - name: basic
    rules:
      - alert: NodeDown
        expr: up == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: '{{ with $labels.name }}{{ . }} {{ end }}{{ $labels.instance }} ({{ $labels.job }}) 응답 없음'
      - alert: DiskAlmostFull
        expr: node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs|overlay|squashfs|nsfs|ramfs"} / node_filesystem_size_bytes < 0.15
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: '{{ with $labels.name }}{{ . }} {{ end }}{{ $labels.instance }} {{ $labels.mountpoint }} 남은 용량 15% 미만'
      - alert: MemoryHigh
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: '{{ with $labels.name }}{{ . }} {{ end }}{{ $labels.instance }} 남은 메모리 10% 미만'
      - alert: CpuHigh
        expr: (1 - avg without (cpu, mode) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100 >= 90
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: '{{ with $labels.name }}{{ . }} {{ end }}{{ $labels.instance }} CPU 90% 이상 (10분)'
EOF

  # 비밀값 파일: 같은 파일(inode)에 덮어써서 컨테이너 bind mount가 유지되게 한다. 값은 출력하지 않는다.
  ( umask 077; printf '%s' "$gpw" > $base/secrets/grafana_admin_password )
  chown 472:0 $base/secrets/grafana_admin_password && chmod 400 $base/secrets/grafana_admin_password
  ( umask 077; printf '%s' "$dw" > $base/secrets/discord_webhook )   # 웹훅이 없으면 빈 파일 (마운트 유지용)
  chown 65534:65534 $base/secrets/discord_webhook && chmod 400 $base/secrets/discord_webhook
  if [[ -n "$dw" ]]; then
    cat > $base/alertmanager.yml <<'EOF'
route:
  receiver: discord
  group_by: [alertname, instance]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
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
  unset gpw dw

  cat > $base/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
deleteDatasources:
  - name: Prometheus
    orgId: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF
  cat > $base/grafana/provisioning/dashboards/durian.yml <<'EOF'
apiVersion: 1
providers:
  - name: durian
    folder: Infra
    type: file
    disableDeletion: true
    allowUiUpdates: false
    updateIntervalSeconds: 60
    options:
      path: /etc/grafana/dashboards
EOF

  cat > $base/.env <<EOF
TZ=${TZ_NAME}
PROMETHEUS_TAG=${prom_tag}
ALERTMANAGER_TAG=${am_tag}
GRAFANA_TAG=${gf_tag}
EOF
  chmod 600 $base/.env
  cat > $base/docker-compose.yml <<'EOF'
name: monitoring
x-hardening: &hardening
  restart: unless-stopped
  cap_drop: [ALL]
  security_opt: ["no-new-privileges:true"]
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "3" }
services:
  prometheus:
    <<: *hardening
    image: prom/prometheus:${PROMETHEUS_TAG}
    container_name: prometheus
    user: "65534:65534"
    environment: [TZ]
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
    extra_hosts: ["host.docker.internal:host-gateway"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
      - ./targets:/etc/prometheus/targets:ro
      - prom-data:/prometheus
    ports: ["127.0.0.1:9090:9090"]
  alertmanager:
    <<: *hardening
    image: prom/alertmanager:${ALERTMANAGER_TAG}
    container_name: alertmanager
    user: "65534:65534"
    environment: [TZ]
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - ./secrets/discord_webhook:/etc/alertmanager/secrets/discord_webhook:ro
      - am-data:/alertmanager
    ports: ["127.0.0.1:9093:9093"]
  grafana:
    <<: *hardening
    image: grafana/grafana:${GRAFANA_TAG}
    container_name: grafana
    user: "472:0"
    environment:
      TZ: ${TZ}
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_USERS_ALLOW_ORG_CREATE: "false"
      GF_SECURITY_DISABLE_GRAVATAR: "true"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
      GF_NEWS_NEWS_FEED_ENABLED: "false"
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
      - ./secrets/grafana_admin_password:/run/secrets/grafana_admin_password:ro
      - grafana-data:/var/lib/grafana
    ports: ["127.0.0.1:3000:3000"]
    depends_on: [prometheus]
volumes:
  prom-data:
  am-data:
  grafana-data:
EOF

  echo "[monitor 4/6] Grafana 대시보드 1860 (Node Exporter Full, rev ${dash_rev}, SHA-256 검증)"
  local raw="$base/grafana/cache/node-exporter-full-rev${dash_rev}.json"
  if ! echo "${dash_sha}  ${raw}" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL --retry 3 "https://grafana.com/api/dashboards/1860/revisions/${dash_rev}/download" -o "${raw}.tmp"
    if ! echo "${dash_sha}  ${raw}.tmp" | sha256sum -c --status; then
      rm -f "${raw}.tmp"
      echo "ERROR: 대시보드 1860 rev ${dash_rev} 해시 불일치 → 설치 중단" >&2
      exit 1
    fi
    mv "${raw}.tmp" "$raw"
  fi
  # rev 46은 데이터 소스를 대시보드 변수(ds_prometheus, type=datasource)로 고르므로 치환 없이 그대로 쓴다.
  # 변수 기본값이 비어 있어 기본 데이터 소스(isDefault: true인 Prometheus)가 자동 선택된다.
  install -m 644 "$raw" $base/grafana/dashboards/node-exporter-full.json

  echo "[monitor 5/6] 설정 검사 (promtool / amtool)"
  docker run --rm --network none --entrypoint promtool \
    -v $base/prometheus.yml:/etc/prometheus/prometheus.yml:ro -v $base/rules:/etc/prometheus/rules:ro \
    "prom/prometheus:${prom_tag}" check config /etc/prometheus/prometheus.yml
  docker run --rm --network none --entrypoint amtool \
    -v $base/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
    -v $base/secrets/discord_webhook:/etc/alertmanager/secrets/discord_webhook:ro \
    "prom/alertmanager:${am_tag}" check-config /etc/alertmanager/alertmanager.yml

  echo "[monitor 6/6] 기동 / 설정 반영"
  (cd $base && docker compose up -d --remove-orphans)
  for url in http://127.0.0.1:9090/-/ready http://127.0.0.1:9093/-/ready http://127.0.0.1:3000/api/health; do
    n=0
    until curl -sf -o /dev/null "$url"; do
      sleep 2; n=$((n+1))
      (( n > 90 )) && { echo "ERROR: $url 응답 없음. 확인: docker compose -f $base/docker-compose.yml logs" >&2; exit 1; }
    done
  done
  # 재실행 시 바뀐 설정 반영 (컨테이너는 그대로, 설정만 다시 읽음)
  docker kill -s HUP prometheus alertmanager >/dev/null
  # 관리자 비밀번호를 SSM 값과 맞춘다 (최초 설치 후 SSM 값을 바꾼 경우)
  docker exec grafana sh -c 'grafana cli admin reset-admin-password --password-from-stdin < /run/secrets/grafana_admin_password' >/dev/null 2>&1 \
    || echo "  WARN: Grafana 관리자 비밀번호 동기화 실패. 확인: docker logs grafana"

  echo "접속: 노트북 PowerShell에서 SSM 포트 포워딩 (포트를 외부에 열지 않음)"
  echo "  aws ssm start-session --target $(imds instance-id) --document-name AWS-StartPortForwardingSession --parameters 'portNumber=3000,localPortNumber=3000'"
  echo "  Grafana http://localhost:3000 (admin, 비밀번호는 $SSM_PREFIX/grafana/admin-password) / 9090 Prometheus / 9093 Alertmanager"
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
