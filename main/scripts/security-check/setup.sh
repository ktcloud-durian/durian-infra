#!/usr/bin/env bash
# 보안 점검기 설치 (Monitor EC2에서 install.sh ROLE=monitor 다음에 1회). 재실행 가능.
# 사용: sudo bash main/scripts/security-check/setup.sh
# 하는 일: 스크립트를 /opt/durian-check에 복사 → 설정 폴더·결과 폴더 만들기 → 매일 08:40 systemd 타이머
#          → Prometheus 경보 규칙 추가 → 한 번 실행해서 Grafana에 값이 들어가는지 확인
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "root(sudo)로 실행하세요"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
DST=/opt/durian-check
ETC=/etc/durian-check
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
RULES=/opt/monitoring/rules

echo "[1/5] 패키지 (jq, OpenStack 명령)"
DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl iproute2 python3-openstackclient >/dev/null
command -v aws >/dev/null || { echo "ERROR: aws 명령 없음. install.sh ROLE=monitor를 먼저 실행" >&2; exit 1; }

echo "[2/5] 스크립트·설정·결과 폴더"
install -d -m 755 "$DST"
install -m 755 "$SRC"/lib.sh "$SRC"/aws.sh "$SRC"/openstack.sh "$SRC"/run.sh "$SRC"/os-baseline.sh "$SRC"/os-write-probe.sh "$DST"/
install -d -m 700 "$ETC" /var/lib/durian-check /var/lib/durian-check/results
[[ -f "$ETC/config.env" ]] || install -m 600 "$SRC/config.env.example" "$ETC/config.env"
[[ -f "$ETC/clouds.yaml" ]] && chmod 600 "$ETC/clouds.yaml"
install -d -m 755 "$TEXTFILE_DIR"
# node_exporter가 이 폴더를 읽는지 확인 (Ubuntu 패키지 기본값). 다른 폴더를 쓰면 경고
args=$(grep -h '^ARGS=' /etc/default/prometheus-node-exporter 2>/dev/null || true)
if [[ "$args" == *textfile.directory* && "$args" != *"$TEXTFILE_DIR"* ]]; then
  echo "  WARN: node_exporter textfile 폴더가 $TEXTFILE_DIR가 아님 ($args). run.sh의 TEXTFILE_DIR를 맞추세요"
fi

echo "[3/5] systemd 타이머 (매일 08:40, 꺼져 있던 동안 놓친 실행은 켜질 때 1회)"
cat > /etc/systemd/system/durian-check.service <<EOF
[Unit]
Description=durian 보안 점검기 (보안 기준서 8.1, 조회 전용)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $DST/run.sh
Environment=HOME=/var/lib/durian-check
TimeoutStartSec=15min
# 조회만 하므로 쓸 수 있는 곳을 결과 폴더와 textfile 폴더로 제한
ProtectSystem=strict
ReadWritePaths=/var/lib/durian-check $TEXTFILE_DIR
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
EOF
cat > /etc/systemd/system/durian-check.timer <<'EOF'
[Unit]
Description=durian 보안 점검기 매일 실행

[Timer]
OnCalendar=*-*-* 08:40:00
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now durian-check.timer

echo "[4/5] Prometheus 경보 규칙 (위반·점검 실패·점검이 멈춤 → Discord ops-alerts)"
if [[ -d "$RULES" ]]; then
  cat > "$RULES/security-check.yml" <<'EOF'
groups:
  - name: security-check
    rules:
      - alert: SecurityCheckFail
        expr: count(durian_check_result == 0) > 0
        labels: { severity: warning }
        annotations:
          summary: '보안 점검 위반 {{ $value }}건. Grafana 보안 관제 대시보드 → 점검 결과 표에서 0인 항목 확인 (보안 기준서 6.3 기록표에 기록)'
      - alert: SecurityCheckError
        expr: count(durian_check_result == -1) > 0
        labels: { severity: warning }
        annotations:
          summary: '보안 점검 {{ $value }}개 항목이 확인 실패(ERROR). 권한·네트워크 문제일 수 있음: sudo journalctl -u durian-check'
      - alert: SecurityCheckStale
        expr: (time() - durian_check_last_success_timestamp_seconds) > 2 * 86400 or absent(durian_check_last_success_timestamp_seconds)
        for: 1h
        labels: { severity: warning }
        annotations:
          summary: '보안 점검이 2일 넘게 성공하지 못함 (안 돌았거나 실행 실패): systemctl status durian-check.timer, journalctl -u durian-check'
EOF
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prometheus; then
    docker exec prometheus promtool check rules /etc/prometheus/rules/security-check.yml
    docker exec prometheus kill -HUP 1
  else
    echo "  WARN: prometheus 컨테이너가 없음. install.sh ROLE=monitor 뒤에 다시 실행하면 규칙이 반영됨"
  fi
else
  echo "  WARN: $RULES 없음 (모니터링 스택 미설치). 경보 규칙은 건너뜀"
fi

echo "[5/5] 한 번 실행하고 메트릭 확인"
systemctl start durian-check.service || true
journalctl -u durian-check.service -n 60 --no-pager | sed 's/^/  /' | tail -45
if curl -sf -m 5 http://127.0.0.1:9100/metrics | grep -q '^durian_check_last_run_timestamp_seconds'; then
  echo "OK: node_exporter에 점검 결과가 보임 → Grafana 보안 관제 대시보드에 1분 안에 나옴"
else
  echo "WARN: node_exporter(9100)에서 durian_check 메트릭이 안 보임. textfile 폴더 설정 확인: cat /etc/default/prometheus-node-exporter"
fi
echo "다음: $ETC/config.env 명단 채우기, OpenStack은 $ETC/clouds.yaml (chmod 600) 넣기 → sudo bash $DST/os-baseline.sh --show a (정의서와 비교) → sudo bash $DST/os-baseline.sh a → sudo systemctl start durian-check"
