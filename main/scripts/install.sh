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
# - 설정 반영은 HUP 신호: docker exec prometheus kill -HUP 1 (--web.enable-lifecycle 사용 안 함)
# - 수집: Node Exporter만 (AWS=ec2_sd_configs 태그 필터, 온프렘=targets/onprem.json, 둘 다 tcp:9100만)
#
# Monitor EC2 전제 조건 (EC2 설정은 AWS 인프라 담당 Terraform이 만든다. 이 스크립트는 바꾸지 않고 확인만 한다)
# - IMDSv2 required + hop limit 2 이상:
#     Prometheus는 Docker 컨테이너(bridge 네트워크) 안에서 ec2_sd_configs로 EC2 API를 부른다.
#     Access Key를 쓰지 않고 인스턴스 역할 자격 증명을 IMDS(169.254.169.254)에서 받는데,
#     컨테이너 → docker0 → 호스트를 거치며 IP 패킷의 홉이 하나 늘어난다.
#     hop limit 1이면 IMDSv2 토큰 응답이 컨테이너까지 오지 못해 자격 증명을 못 받고,
#     node-aws 대상이 0개가 된다 (Prometheus 로그에 ec2 discovery 오류).
#     설치 시작 때 이 값을 읽어 2 미만이면 WARN만 출력하고 설치는 계속한다.
# - 인스턴스 역할 권한:
#     필수: ec2:DescribeInstances (ec2_sd 노드 발견, 설치 시 hop limit 확인)
#     선택: ec2:DescribeAvailabilityZones (AZ ID 라벨 __meta_ec2_availability_zone_id용, 팀 역할에는 없음)
#     필수: ssm:GetParameter (SSM_PREFIX/grafana/admin-password, SSM_PREFIX/ops/discord-webhook)
#     필수: SSM 접속 (AmazonSSMManagedInstanceCore)
# - 보안그룹: 인바운드 0개. 아웃바운드 443(SSM·EC2 API·Docker Hub·grafana.com), 80(apt), 노드 SG로 9100
#
# 컨테이너 이미지는 "이미지:태그@sha256:digest"로 고정한다 (태그는 읽기 쉽게 남겨 둔 표시일 뿐)
# - Docker는 태그와 digest가 같이 있으면 digest만 보고 받는다. 태그만 바꾸고 digest를 그대로 두면
#   경고 없이 이전 버전이 받아진다. 태그를 바꿀 때는 반드시 digest도 같이 바꾼다 (기본값·변수 모두)
# - digest는 여러 아키텍처 목록(index) digest를 쓴다. 확인 명령 (맨 위 Digest 값):
#     docker buildx imagetools inspect prom/prometheus:v3.5.0
#     docker buildx imagetools inspect prom/alertmanager:v0.28.1
#     docker buildx imagetools inspect grafana/grafana:12.0.2
#   buildx가 없으면 레지스트리에 HEAD /v2/<저장소>/manifests/<태그> 요청 (Accept: manifest list / OCI index)을
#   보내 응답 헤더 Docker-Content-Digest 값을 쓴다
# - 변수에는 "sha256:" 뒤의 64자리만 넣는다 (앞에 sha256:을 붙여도 떼어 내고, 형식이 틀리면 설치 중단)
#
# 변수: NODE_TAG_KEY(기본 Role) NODE_TAG_VALUES(기본 master,worker, 쉼표 구분)
#       PROMETHEUS_TAG / ALERTMANAGER_TAG / GRAFANA_TAG
#       PROMETHEUS_DIGEST / ALERTMANAGER_DIGEST / GRAFANA_DIGEST (태그와 짝으로 바꿈)
#       DASH_NODE_FULL_REV / DASH_NODE_FULL_SHA256
#
# Grafana 임베드(iframe) 옵션 — 기본값은 꺼짐. 두 변수 모두 비어 있으면 Grafana 설정은 이전과 완전히 같다
#   (allow_embedding 꺼짐 → X-Frame-Options: deny 유지, CSP 꺼짐, 쿠키 기본값, docker-compose.yml 동일)
# - GRAFANA_EMBED_ORIGIN (기본 빈 값): Grafana 패널을 iframe으로 넣을 화면의 주소 하나 (예: https://soc.example.com)
#     https://로 시작하는 origin 하나만 허용 (경로·쉼표·공백·와일드카드·http:// 불가). 틀리면 설치 중단
#     값이 있으면: GF_SECURITY_ALLOW_EMBEDDING=true
#                  GF_SECURITY_CONTENT_SECURITY_POLICY=true, frame-ancestors는 'self' + 이 주소만 (클릭재킹 완화)
#                  GF_SECURITY_COOKIE_SAMESITE=none, GF_SECURITY_COOKIE_SECURE=true (iframe 안 로그인 쿠키용)
# - GRAFANA_ROOT_URL (기본 빈 값): 값이 있으면 GF_SERVER_ROOT_URL로 전달 (예: tailscale serve의 HTTPS 주소)
# - 익명 접근(GF_AUTH_ANONYMOUS_ENABLED)은 이 옵션과 관계없이 항상 "false" (NET-06). 임베드는 로그인(Viewer) 방식만
# - 켤 때 필요한 조건:
#     1) 보안 담당 승인 (보안 설정 변경)
#     2) SOC 화면에서 Grafana에 HTTPS로 접속할 수 있어야 함 (SameSite=None 쿠키는 Secure 필수 → http 주소로는
#        iframe 안 로그인이 안 됨). 보통 GRAFANA_ROOT_URL에 그 HTTPS 주소를 같이 넣는다
#     SSM 포트 포워딩(http://localhost:3000) 접속은 켠 뒤에도 그대로 쓴다 (브라우저가 localhost는 보안 출처로 취급)
monitor() {
  local base=/opt/monitoring
  local prom_tag="${PROMETHEUS_TAG:-v3.5.0}" am_tag="${ALERTMANAGER_TAG:-v0.28.1}" gf_tag="${GRAFANA_TAG:-12.0.2}"
  local prom_dig="${PROMETHEUS_DIGEST:-63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996}"
  local am_dig="${ALERTMANAGER_DIGEST:-27c475db5fb156cab31d5c18a4251ac7ed567746a2483ff264516437a39b15ba}"
  local gf_dig="${GRAFANA_DIGEST:-b5b59bfc7561634c2d7b136c4543d702ebcc94a3da477f21ff26f89ffd4214fa}"
  local d
  prom_dig="${prom_dig#sha256:}"; am_dig="${am_dig#sha256:}"; gf_dig="${gf_dig#sha256:}"
  for d in "$prom_dig" "$am_dig" "$gf_dig"; do
    if [[ ! "$d" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: 이미지 digest 형식 오류 (sha256 64자리 16진수여야 함): $d" >&2
      exit 1
    fi
  done
  local tag_key="${NODE_TAG_KEY:-Role}" tag_values="${NODE_TAG_VALUES:-master,worker}"
  local dash_rev="${DASH_NODE_FULL_REV:-46}"
  local dash_sha="${DASH_NODE_FULL_SHA256:-e58ddc5dc535d4c901f94da9648bc3e3d5ae7b6f78e98e185bce8b289961cea3}"
  local dw gpw tagvals v url n iid hop re='[^A-Za-z0-9,._:/+=@-]'
  local -a vals

  echo "[monitor 1/6] 사전 확인 (IMDS hop limit, SSM 비밀값, 변수)"
  # hop limit 확인 (위 '전제 조건' 참고). 실패하거나 2 미만이면 경고만 하고 계속한다.
  iid=$(imds instance-id)
  hop=""
  [[ -n "$iid" ]] && hop=$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit' --output text 2>/dev/null || true)
  if [[ "$hop" =~ ^[0-9]+$ ]]; then
    if (( hop < 2 )); then
      echo "  WARN: IMDS hop limit=$hop (2 이상 필요). Prometheus 컨테이너가 EC2 자동 발견을 못 해 AWS 노드가 수집되지 않음"
      echo "        → AWS 인프라 담당에게 Monitor EC2의 http_put_response_hop_limit=2 요청 (설치는 계속)"
    else
      echo "  IMDS hop limit=$hop (OK)"
    fi
  else
    echo "  WARN: IMDS hop limit 확인 불가 (IMDS 응답 없음 또는 ec2:DescribeInstances 권한 없음). 설치는 계속"
  fi
  gpw=$(ssm_get "$SSM_PREFIX/grafana/admin-password")
  if [[ -z "$gpw" ]]; then
    echo "ERROR: Grafana 비밀번호($SSM_PREFIX/grafana/admin-password)가 SSM에 없거나 읽을 권한 없음 → 설치 중단" >&2
    exit 1
  fi
  dw=$(ssm_get "$SSM_PREFIX/ops/discord-webhook")   # 팀: /durian/ops/discord-webhook (ops-alerts 채널)
  if [[ "$tag_key$tag_values" =~ $re ]]; then
    echo "ERROR: NODE_TAG_KEY/NODE_TAG_VALUES에 허용되지 않는 문자 (영문, 숫자, , . _ : / + = @ - 만)" >&2
    exit 1
  fi
  IFS=',' read -ra vals <<< "$tag_values"
  tagvals=""
  for v in "${vals[@]}"; do tagvals+="\"$v\", "; done
  tagvals="[${tagvals%, }]"
  # Grafana 임베드 옵션 (함수 위 주석 참고). 기본은 둘 다 빈 값 = 꺼짐
  local embed_origin="${GRAFANA_EMBED_ORIGIN:-}" root_url="${GRAFANA_ROOT_URL:-}"
  embed_origin="${embed_origin%/}"
  if [[ -n "$embed_origin" && ! "$embed_origin" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; then
    echo "ERROR: GRAFANA_EMBED_ORIGIN 형식 오류: https://로 시작하는 주소(origin) 하나만 허용 (예: https://soc.example.com)" >&2
    echo "       경로, 쉼표/공백으로 여러 개, 와일드카드(*), http:// 는 허용하지 않음 → 설치 중단" >&2
    exit 1
  fi
  if [[ -n "$root_url" && ! "$root_url" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "ERROR: GRAFANA_ROOT_URL 형식 오류: http(s)://호스트[:포트][/경로] 하나만 허용 → 설치 중단" >&2
    exit 1
  fi
  if [[ -n "$embed_origin" ]]; then
    echo "  Grafana 임베드 켜짐: frame-ancestors 'self' $embed_origin (익명 접근은 계속 꺼짐)"
    [[ "$root_url" == https://* ]] || echo "  WARN: GRAFANA_ROOT_URL이 HTTPS가 아님. SOC 화면 iframe 안 로그인은 Grafana가 HTTPS일 때만 동작"
  fi

  echo "[monitor 2/6] Docker"
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
  systemctl enable --now docker

  echo "[monitor 3/6] 설정 파일 생성 ($base)"
  mkdir -p $base/{targets,rules,secrets,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/provisioning/plugins,grafana/provisioning/alerting,grafana/dashboards,grafana/cache}
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
  # AWS 노드: EC2 태그로 자동 발견, 포트는 9100 고정 (인스턴스 역할 + IMDSv2 hop limit 2 필요: 함수 위 '전제 조건')
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
      # 허용 포트 목록 7.2: Monitor → 온프렘은 tcp:9100만. 다른 포트가 적힌 대상은 수집하지 않고 버린다
      - source_labels: [__address__]
        regex: '.+:9100'
        action: keep
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
    echo "  Discord 웹훅($SSM_PREFIX/ops/discord-webhook) 없음 → 알림 전송 없이 설치"
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
PROMETHEUS_DIGEST=${prom_dig}
ALERTMANAGER_DIGEST=${am_dig}
GRAFANA_DIGEST=${gf_dig}
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
    image: prom/prometheus:${PROMETHEUS_TAG}@sha256:${PROMETHEUS_DIGEST}
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
    image: prom/alertmanager:${ALERTMANAGER_TAG}@sha256:${ALERTMANAGER_DIGEST}
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
    image: grafana/grafana:${GRAFANA_TAG}@sha256:${GRAFANA_DIGEST}
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
EOF
  # 임베드 옵션 (기본 꺼짐: 아래 두 블록 모두 건너뛰어 docker-compose.yml이 이전과 같다)
  # CSP 템플릿은 Grafana 기본 템플릿 끝에 frame-ancestors만 더한 것. $$는 compose에서 Grafana 변수($NONCE 등)를 그대로 넘기려는 표기
  if [[ -n "$embed_origin" ]]; then
    sed "s|__EMBED_ORIGIN__|${embed_origin}|" >> $base/docker-compose.yml <<'EOF'
      GF_SECURITY_ALLOW_EMBEDDING: "true"
      GF_SECURITY_CONTENT_SECURITY_POLICY: "true"
      GF_SECURITY_CONTENT_SECURITY_POLICY_TEMPLATE: "script-src 'self' 'unsafe-eval' 'unsafe-inline' 'strict-dynamic' $$NONCE;object-src 'none';font-src 'self';style-src 'self' 'unsafe-inline' blob:;img-src * data:;base-uri 'self';connect-src 'self' grafana.com ws://$$ROOT_PATH wss://$$ROOT_PATH;manifest-src 'self';media-src 'none';form-action 'self';frame-ancestors 'self' __EMBED_ORIGIN__;"
      GF_SECURITY_COOKIE_SAMESITE: "none"
      GF_SECURITY_COOKIE_SECURE: "true"
EOF
  fi
  [[ -n "$root_url" ]] && printf '      GF_SERVER_ROOT_URL: "%s"\n' "$root_url" >> $base/docker-compose.yml
  cat >> $base/docker-compose.yml <<'EOF'
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

  bash "$(dirname "${BASH_SOURCE[0]}")/monitoring/security-dashboard.sh" $base || { echo "[WARN] security-dashboard.sh failed" >&2; }  # LOG-05~07

  echo "[monitor 5/6] 설정 검사 (promtool / amtool)"
  docker run --rm --network none --entrypoint promtool \
    -v $base/prometheus.yml:/etc/prometheus/prometheus.yml:ro -v $base/rules:/etc/prometheus/rules:ro \
    "prom/prometheus:${prom_tag}@sha256:${prom_dig}" check config /etc/prometheus/prometheus.yml
  docker run --rm --network none --entrypoint amtool \
    -v $base/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
    -v $base/secrets/discord_webhook:/etc/alertmanager/secrets/discord_webhook:ro \
    "prom/alertmanager:${am_tag}@sha256:${am_dig}" check-config /etc/alertmanager/alertmanager.yml

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
  # 주의: 'docker kill -s HUP'은 Docker가 컨테이너를 "수동 중지"로 표시해서, 재부팅 뒤
  # restart: unless-stopped 컨테이너가 다시 올라오지 않는다. 그래서 컨테이너 안에서 PID 1에 HUP을 보낸다.
  docker exec prometheus kill -HUP 1
  docker exec alertmanager kill -HUP 1
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
