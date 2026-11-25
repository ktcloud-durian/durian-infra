#!/usr/bin/env bash
# OS-IAM04 쓰기 시험: 점검용 reader 계정으로 보안그룹을 만들어 봄 → 403(거부)이어야 통과 (IAM-04 최소 권한)
# 실제 리소스를 바꿀 수 있는 시험이라 매일 도는 조회 전용 점검(run.sh)과 분리함. 사람이 날짜를 정해 수동으로 실행 (주 1회, 권한 바꾼 뒤)
# 만들어지면(=쓰기 권한 있음) FAIL로 남기고 바로 지움. 결과는 write-probe-<사이트>.json → 다음 정기 점검이 읽어 대시보드에 보여 줌
# 사용: sudo bash os-write-probe.sh a [b]
set -uo pipefail
CONF=${CONF:-/etc/durian-check/config.env}
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
export OS_CLIENT_CONFIG_FILE=${OS_CLIENT_CONFIG_FILE:-/etc/durian-check/clouds.yaml}
DIR=${PROBE_DIR:-/var/lib/durian-check}
[[ $# -ge 1 ]] || { sed -n '2,5p' "$0"; exit 1; }
command -v openstack >/dev/null || { echo "openstack 명령 없음"; exit 1; }
umask 077

save() { # save 사이트 결과 상세
  jq -nc --arg d "$(date '+%F %H:%M')" --arg r "$2" --arg t "$3" '{date: $d, result: $r, detail: $t}' > "$DIR/write-probe-$1.json"
  printf '%-5s %s  %s\n' "$2" "$1" "$3"
}

rc=0
for SITE in "$@"; do
  P="durian-$SITE"
  name="durian-reader-write-test-$(date +%s)"
  if out=$(openstack --os-cloud "$P" security group create "$name" --description "durian reader write test, delete" 2>&1); then
    if openstack --os-cloud "$P" security group delete "$name" >/dev/null 2>&1; then d="테스트 그룹 삭제함"
    else d="❗ 테스트 그룹 $name 삭제 실패 → OpenStack 인프라 담당에게 삭제 요청"; fi
    save "$SITE" FAIL "reader 계정으로 보안그룹이 만들어짐 (쓰기 권한 있음). $d"; rc=1
  elif grep -qiE "403|forbidden|not authorized|policy" <<<"$out"; then save "$SITE" PASS "보안그룹 만들기 403 거부"
  else save "$SITE" ERROR "403이 아닌 이유로 실패: $(head -c 150 <<<"$out" | tr '\n' ' ')"; rc=1; fi
done
exit $rc
