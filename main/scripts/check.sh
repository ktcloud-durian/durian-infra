#!/usr/bin/env bash
# durian 서버 설치 상태 점검 (읽기 전용, 비밀값 출력 안 함)
# 사용: sudo bash check.sh            (역할 자동 감지)
#       sudo ROLE=master bash check.sh (역할 지정)
set -uo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SSM_PREFIX="${SSM_PREFIX:-/durian}"
TZ_EXPECT="${TZ_NAME:-Asia/Seoul}"
export AWS_DEFAULT_REGION="$AWS_REGION" KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
warn() { echo "  [주의] $*"; WARN=$((WARN+1)); }
bad()  { echo "  [실패] $*"; FAIL=$((FAIL+1)); }
sec()  { echo; echo "== $* =="; }
has()  { command -v "$1" >/dev/null 2>&1; }
active() { systemctl is-active --quiet "$1" 2>/dev/null; }
listen() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
imds() {
  local t; t=$(curl -sf -m 3 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 0
  curl -sf -m 3 -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1" || true
}

# ---------- 역할 감지 ----------
if [[ -z "${ROLE:-}" ]]; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^k3s.service'; then ROLE=master
  elif systemctl list-unit-files 2>/dev/null | grep -q '^k3s-agent.service'; then ROLE=worker
  elif [[ -f /opt/monitoring/docker-compose.yml ]]; then ROLE=monitor
  else ROLE=unknown; fi
fi
echo "durian 설치 점검  호스트=$(hostname)  역할=$ROLE  시각=$(date '+%F %T %Z')"

# ---------- 공통 ----------
sec "서버 정보"
echo "  인스턴스 ID : $(imds instance-id)"
echo "  AZ          : $(imds placement/availability-zone)"
echo "  사설 IP     : $(imds local-ipv4)"
echo "  공인 IP     : $(imds public-ipv4)"
echo "  디스크(/)   : $(df -h / | awk 'NR==2{print $3" 사용 / "$2" ("$5")"}')"
echo "  메모리      : $(free -h | awk '/Mem:/{print $3" 사용 / "$2}')"
if [[ "$(imds iam/info)" == *InstanceProfileArn* ]]; then ok "IAM 인스턴스 프로파일 연결됨"; else bad "IAM 인스턴스 프로파일 없음"; fi

sec "공통 설정"
tz=$(timedatectl show -p Timezone --value 2>/dev/null)
[[ "$tz" == "$TZ_EXPECT" ]] && ok "시간대 $tz" || bad "시간대 $tz (기대: $TZ_EXPECT)"
if active chrony; then
  ok "chrony 동작 ($(chronyc tracking 2>/dev/null | awk '/Reference ID/{print $5}' | tr -d '()'))"
else bad "chrony 중지됨"; fi
for c in curl unzip jq aws; do has "$c" && ok "$c 설치됨" || bad "$c 없음"; done
if active prometheus-node-exporter && listen 9100; then ok "node-exporter 동작 (9100)"; else bad "node-exporter 동작 안 함"; fi
if active snap.amazon-ssm-agent.amazon-ssm-agent || active amazon-ssm-agent; then ok "SSM Agent 동작"; else warn "SSM Agent 상태 확인 필요"; fi
if curl -sf -m 5 -o /dev/null https://github.com; then ok "인터넷(GitHub) 접근 가능"; else bad "인터넷 접근 불가 (NAT/라우트 확인)"; fi

sec "Tailscale"
if has tailscale; then
  ok "tailscale 설치됨"
  st=$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null)
  if [[ "$st" == "Running" ]]; then ok "로그인됨  IP=$(tailscale ip -4 2>/dev/null | head -1)"
  else warn "로그인 안 됨 (상태: ${st:-알 수 없음}) → tailscale up 필요"; fi
else bad "tailscale 없음"; fi

# ---------- master ----------
check_master() {
  sec "K3s master"
  active k3s && ok "k3s 서비스 동작 ($(k3s --version 2>/dev/null | head -1))" || { bad "k3s 서비스 중지"; return; }
  echo "  --- 노드 ---"; kubectl get nodes -o wide 2>&1 | sed 's/^/  /'
  kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{f=1} END{exit f}' && ok "모든 노드 Ready" || bad "Ready 아닌 노드 있음"
  np=$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.ports[*].nodePort}' 2>/dev/null)
  [[ "$np" == *30080* ]] && ok "Traefik NodePort 설정됨 ($np)" || warn "Traefik NodePort 미설정 ($np)"

  sec "Argo CD"
  if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
    notready=$(kubectl -n argocd get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]!=a[2]||$3!="Running")c++} END{print c+0}')
    [[ "$notready" == 0 ]] && ok "Argo CD Pod 모두 정상" || bad "Argo CD Pod $notready개 비정상"
    echo "  --- Application ---"; kubectl get applications -n argocd 2>&1 | sed 's/^/  /'
    kubectl get applications -n argocd --no-headers 2>/dev/null | awk '$2!="Synced"||$3!="Healthy"{f=1} END{exit f}' \
      && ok "Application 모두 Synced/Healthy" || warn "Synced/Healthy 아닌 Application 있음"
  else bad "Argo CD 미설치"; fi

  sec "기타 구성"
  kubectl -n monitoring get deploy kube-state-metrics >/dev/null 2>&1 && ok "kube-state-metrics 설치됨" || warn "kube-state-metrics 없음"
  has helm && ok "helm $(helm version --short 2>/dev/null)" || bad "helm 없음"
  kubectl get ns velero >/dev/null 2>&1 && ok "Velero 설치됨" || echo "  (Velero 미설치 - 선택 항목)"
  for p in k3s/token k3s/master-ip; do
    if aws ssm get-parameter --name "$SSM_PREFIX/$p" --query Parameter.Name --output text >/dev/null 2>&1
    then ok "SSM $SSM_PREFIX/$p 저장됨"; else warn "SSM $SSM_PREFIX/$p 없음 (IAM 권한 확인)"; fi
  done
  echo "  --- 비정상 Pod (전체 네임스페이스) ---"
  kubectl get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if($4!="Running"&&$4!="Completed")print "  "$0}' | head -10
}

# ---------- worker ----------
check_worker() {
  sec "K3s worker"
  active k3s-agent && ok "k3s-agent 동작 ($(k3s --version 2>/dev/null | head -1))" || { bad "k3s-agent 중지"; return; }
  url=$(grep -h '^K3S_URL=' /etc/systemd/system/k3s-agent.service.env 2>/dev/null | cut -d= -f2-)
  echo "  master 주소: ${url:-알 수 없음}"
  if [[ -n "$url" ]] && curl -ksf -m 5 "$url/cacerts" >/dev/null; then ok "master 6443 접근 가능"; else bad "master 접근 불가 (SG 6443 확인)"; fi
  echo "  (노드 Ready 여부는 master에서: kubectl get nodes)"
}

# ---------- monitor ----------
check_monitor() {
  sec "Monitor"
  active docker && ok "docker 동작" || { bad "docker 중지"; return; }
  echo "  --- 컨테이너 ---"; (cd /opt/monitoring && docker compose ps 2>&1 | sed 's/^/  /')
  curl -sf -m 5 http://localhost:9090/-/ready >/dev/null && ok "Prometheus 준비됨 (9090)" || bad "Prometheus 응답 없음"
  curl -sf -m 5 http://localhost:9093/-/ready >/dev/null && ok "Alertmanager 준비됨 (9093)" || bad "Alertmanager 응답 없음"
  curl -sf -m 5 http://localhost:3000/api/health >/dev/null && ok "Grafana 준비됨 (3000)" || bad "Grafana 응답 없음"
  t=$(curl -sf -m 5 http://localhost:9090/api/v1/targets 2>/dev/null)
  if [[ -n "$t" ]]; then
    up=$(echo "$t" | jq '[.data.activeTargets[]|select(.health=="up")]|length')
    down=$(echo "$t" | jq '[.data.activeTargets[]|select(.health!="up")]|length')
    [[ "$down" == 0 ]] && ok "수집 대상 정상 ($up개)" || warn "수집 대상 up=$up / down=$down"
    echo "$t" | jq -r '.data.activeTargets[]|select(.health!="up")|"    down: "+.scrapeUrl' 2>/dev/null
  fi
  [[ -s /opt/monitoring/secrets/discord_webhook ]] && ok "Discord 웹훅 설정됨" || warn "Discord 웹훅 없음 (알림 미전송)"
  [[ -f /root/grafana-admin-password ]] && echo "  Grafana 비밀번호 파일: /root/grafana-admin-password (직접 확인)"
}

case "$ROLE" in
  master) check_master ;; worker) check_worker ;; monitor) check_monitor ;;
  *) warn "역할을 감지하지 못함 (설치 전이거나 ROLE=... 로 지정)" ;;
esac

echo; echo "== 요약: 정상 $PASS / 주의 $WARN / 실패 $FAIL =="
echo "  설치 로그: /var/log/durian-install.log"
exit $(( FAIL > 0 ))
