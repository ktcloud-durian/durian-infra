#!/usr/bin/env bash
# Grafana 보안 관제 줄 (보안 담당, LOG-05·06·07): CloudWatch(서울) sec-responder 로그·Lambda 지표·durian/CIS 지표
# install.sh monitor 단계에서 부름. k3s User Data(16KiB 제한)에 install.sh가 통째로 들어가서 이 부분만 따로 둠.
# 액세스 키 없이 Monitor EC2 역할로 읽음 (monitor-ec2.tf의 Durian-Monitor-ReadOnly 정책, hop limit 2)
# 사용: sudo bash security-dashboard.sh /opt/monitoring
set -euo pipefail
base=${1:-/opt/monitoring}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d $base/grafana/provisioning/datasources && -d $base/grafana/dashboards ]] || { echo "  WARN: $base 에 Grafana 폴더 없음 (install.sh monitor 먼저)"; exit 1; }

cat > "$base/grafana/provisioning/datasources/cloudwatch.yml" <<'YML'
apiVersion: 1
datasources:
  - name: CloudWatch
    uid: cloudwatch
    type: cloudwatch
    editable: false
    jsonData:
      authType: default
      defaultRegion: ap-northeast-2
YML
install -m 644 "$here/security-dashboard.json" "$base/grafana/dashboards/security-dashboard.json"
echo "  보안 관제 대시보드·CloudWatch 데이터 소스 설정 완료"

# Grafana reload datasource provisioning
docker restart grafana 2>/dev/null && echo "[LOG-07] Grafana restarted for CloudWatch datasource" || echo "[WARN] Grafana restart failed" >&2