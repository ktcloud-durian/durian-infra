#!/usr/bin/env bash
# 보안 점검기 실행 (Monitor EC2, systemd 타이머가 부름). AWS·OpenStack을 점검하고
# 1) 결과를 날짜별 폴더에 JSON 줄로 남기고  2) node_exporter textfile로 내보내 Grafana 보안 관제 대시보드에 띄움.
# 사용: sudo bash run.sh            (설정: /etc/durian-check/config.env)
# 메트릭: durian_check_result{id,cloud,site,area,criterion} 1=PASS 0=FAIL -1=ERROR (SKIP은 내보내지 않음)
#         durian_check_last_run_timestamp_seconds, durian_check_items{result}
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${CONF:-/etc/durian-check/config.env}
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
export NAME REGION ADMINS KEY_USERS STATE_BUCKET GLOBAL OS_SITES TEAM_USERS APPROVED_ADMINS FIP_ALLOW_SERVERS DB_NAME_PATTERN MANAGED_IDS_DIR OS_CLIENT_CONFIG_FILE 2>/dev/null || true

RESULTS=${RESULTS:-/var/lib/durian-check/results}
TEXTFILE_DIR=${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}
KEEP_DAYS=${KEEP_DAYS:-60}
OUT="$RESULTS/$(date +%F_%H%M)"; export OUT
umask 077; mkdir -p "$OUT"

echo "== AWS =="
bash "$HERE/aws.sh"
echo "== OpenStack =="
bash "$HERE/openstack.sh"

# ---------- textfile로 내보내기 ----------
# 점검표 번호 → 영역 (보안 기준서 8.1 표의 '영역' 열)
AREA='def area: if test("^(7|8|9a|9b|10|11|12|OS-A.*|OS-IAM04)$") then "계정·권한"
  elif test("^(14|15|19|20|21.|22.|OS-R.*|OS-20)$") then "리소스"
  elif test("^(25.|26.)$") then "탐지·대응" else "기타" end;'
tmp=$(mktemp "$TEXTFILE_DIR/.durian_check.XXXXXX") || { echo "ERROR: $TEXTFILE_DIR에 쓸 수 없음" >&2; exit 1; }
{
  echo "# HELP durian_check_result 보안 점검 결과 (1=PASS, 0=FAIL, -1=ERROR)"
  echo "# TYPE durian_check_result gauge"
  cat "$OUT"/*.jsonl 2>/dev/null | jq -r "$AREA"' select(.result != "SKIP")
    | "durian_check_result{id=\"\(.no)\",cloud=\"\(.cloud)\",site=\"\(.site)\",area=\"\(.no | area)\",criterion=\"\(.criterion)\"} \(if .result=="PASS" then 1 elif .result=="FAIL" then 0 else -1 end)"'
  echo "# HELP durian_check_items 결과별 항목 수"
  echo "# TYPE durian_check_items gauge"
  for r in PASS FAIL ERROR SKIP; do
    printf 'durian_check_items{result="%s"} %s\n' "$r" "$(cat "$OUT"/*.jsonl 2>/dev/null | jq -s --arg r "$r" '[.[] | select(.result==$r)] | length')"
  done
  echo "# HELP durian_check_last_run_timestamp_seconds 마지막 점검 시각 (유닉스 시간)"
  echo "# TYPE durian_check_last_run_timestamp_seconds gauge"
  echo "durian_check_last_run_timestamp_seconds $(date +%s)"
} > "$tmp"
chmod 644 "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/durian_check.prom"

# 오래된 결과 정리 (credential report CSV 포함)
find "$RESULTS" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
echo "결과: $OUT  /  메트릭: $TEXTFILE_DIR/durian_check.prom"
