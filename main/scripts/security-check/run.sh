#!/usr/bin/env bash
# 보안 점검기 실행 (Monitor EC2, systemd 타이머가 부름). AWS·OpenStack을 점검하고
# 1) 결과를 날짜별 폴더에 JSON 줄로 남기고  2) node_exporter textfile로 내보내 Grafana 보안 관제 대시보드에 띄움.
# 사용: sudo bash run.sh            (설정: /etc/durian-check/config.env)
# 메트릭: durian_check_result{id,cloud,site,area,criterion} 1=PASS 0=FAIL -1=ERROR 2=EXCEPT(승인 예외) (SKIP은 내보내지 않음)
#         durian_check_last_run_timestamp_seconds(돌린 시각), durian_check_last_success_timestamp_seconds(실행 실패 없이 끝난 시각)
#         durian_check_items{result}
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${CONF:-/etc/durian-check/config.env}
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
export NAME REGION ADMINS KEY_USERS STATE_BUCKET GLOBAL GUARDDUTY APPROVED_EXCEPTIONS OS_SITES TEAM_USERS APPROVED_ADMINS FIP_ALLOW_SERVERS DB_NAME_PATTERN MANAGED_IDS_DIR OS_CLIENT_CONFIG_FILE 2>/dev/null || true

RESULTS=${RESULTS:-/var/lib/durian-check/results}
TEXTFILE_DIR=${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}
KEEP_DAYS=${KEEP_DAYS:-60}
OUT="$RESULTS/$(date +%F_%H%M%S)"; export OUT   # 초까지: 같은 분에 두 번 돌려도 결과가 섞이지 않게
umask 077; mkdir -p "$OUT"

# 점검 스크립트가 중간에 죽으면(종료 코드 ≠ 0, 결과 파일 없음) 빠진 항목이 '문제없음'으로 보이지 않게 ERROR 한 줄을 남김
ok=true
run_check() { # run_check aws|openstack
  local rc=0
  bash "$HERE/$1.sh" || rc=$?
  if (( rc != 0 )) || [[ ! -s "$OUT/$1.jsonl" ]]; then
    ok=false
    jq -nc --arg c "$1" --arg d "$1.sh 실행 실패 (종료 코드 $rc, 결과 $(cat "$OUT/$1.jsonl" 2>/dev/null | wc -l)줄). 빠진 항목이 있을 수 있음: journalctl -u durian-check" \
      '{no: ("RUN-" + $c), criterion: "점검 실행", cloud: $c, site: "", result: "ERROR", detail: $d}' >> "$OUT/$1.jsonl"
    echo "ERROR  $1.sh 실행 실패 (종료 코드 $rc)" >&2
  fi
}
echo "== AWS =="
run_check aws
echo "== OpenStack =="
run_check openstack

# ---------- textfile로 내보내기 ----------
# 점검표 번호 → 영역 (보안 기준서 8.1 표의 '영역' 열)
AREA='def area: if test("^(7|8|9a|9b|10|11|12|OS-A.*|OS-IAM04)$") then "계정·권한"
  elif test("^(14|15|19|20|21.|22.|OS-R.*|OS-20)$") then "리소스"
  elif test("^(25.|26.)$") then "탐지·대응" else "기타" end;'
now=$(date +%s)
prev_ok=$(awk '$1 == "durian_check_last_success_timestamp_seconds" {print $2}' "$TEXTFILE_DIR/durian_check.prom" 2>/dev/null || true)
tmp=$(mktemp "$TEXTFILE_DIR/.durian_check.XXXXXX") || { echo "ERROR: $TEXTFILE_DIR에 쓸 수 없음" >&2; exit 1; }
{
  echo "# HELP durian_check_result 보안 점검 결과 (1=PASS, 0=FAIL, -1=ERROR, 2=승인 예외)"
  echo "# TYPE durian_check_result gauge"
  cat "$OUT"/*.jsonl 2>/dev/null | jq -r "$AREA"' select(.result != "SKIP")
    | "durian_check_result{id=\"\(.no)\",cloud=\"\(.cloud)\",site=\"\(.site)\",area=\"\(.no | area)\",criterion=\"\(.criterion)\"} \(if .result=="PASS" then 1 elif .result=="FAIL" then 0 elif .result=="EXCEPT" then 2 else -1 end)"'
  echo "# HELP durian_check_items 결과별 항목 수"
  echo "# TYPE durian_check_items gauge"
  for r in PASS FAIL ERROR EXCEPT SKIP; do
    printf 'durian_check_items{result="%s"} %s\n' "$r" "$(cat "$OUT"/*.jsonl 2>/dev/null | jq -s --arg r "$r" '[.[] | select(.result==$r)] | length')"
  done
  echo "# HELP durian_check_last_run_timestamp_seconds 마지막 점검 시각 (유닉스 시간)"
  echo "# TYPE durian_check_last_run_timestamp_seconds gauge"
  echo "durian_check_last_run_timestamp_seconds $now"
  # 마지막 성공 시각은 실행 실패가 없을 때만 갱신 (실패하면 이전 값 유지 → 계속 실패하면 SecurityCheckStale)
  echo "# HELP durian_check_last_success_timestamp_seconds 실행 실패 없이 끝난 마지막 점검 시각"
  echo "# TYPE durian_check_last_success_timestamp_seconds gauge"
  if $ok; then echo "durian_check_last_success_timestamp_seconds $now"
  elif [[ -n "$prev_ok" ]]; then echo "durian_check_last_success_timestamp_seconds $prev_ok"; fi
} > "$tmp"
chmod 644 "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/durian_check.prom"

# 오래된 결과 정리 (credential report CSV 포함)
find "$RESULTS" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
echo "결과: $OUT  /  메트릭: $TEXTFILE_DIR/durian_check.prom"
$ok || exit 1   # systemd에도 실패로 남김 (journalctl, systemctl --failed)
