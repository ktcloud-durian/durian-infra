# shellcheck shell=bash
# 점검기 공용 함수 (aws.sh·openstack.sh가 source). 직접 실행하지 않음.
# 결과 한 줄 = {"no","criterion","cloud","site","result","detail"}  (site는 OpenStack 사이트 a·b, AWS는 빈 값)  result: PASS | FAIL | ERROR | SKIP
# 원칙: 명령이 실패하면(권한 부족·세션 만료·네트워크) 빈 결과가 '통과'로 보이지 않게 ERROR로 남김.
#       detail에는 리소스 ID·이름만 넣고 비밀번호·키·토큰 값은 넣지 않음.

: "${OUT:?OUT(결과 폴더)이 필요함}"
: "${CLOUD_NAME:?CLOUD_NAME(aws|openstack)이 필요함}"
mkdir -p "$OUT"
JSONL="$OUT/${CLOUD_NAME}.jsonl"
ERRF="$OUT/${CLOUD_NAME}.last.err"
: > "$JSONL"
pass=0; fail=0; err=0; skip=0

result() { # result 번호 기준 PASS|FAIL|ERROR|SKIP 상세
  set -- "$1" "$2" "$3" "$(sed -E 's/[0-9]{12}/<계정ID>/g' <<<"${4:-}")"   # 오류 메시지의 ARN 등에서 계정 ID 가림
  jq -nc --arg no "$1" --arg c "$2" --arg cl "$CLOUD_NAME" --arg s "${SITE:-}" --arg r "$3" --arg d "${4:0:500}" \
    '{no:$no, criterion:$c, cloud:$cl, site:$s, result:$r, detail:$d}' >> "$JSONL"
  case "$3" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; ERROR) err=$((err+1));; *) skip=$((skip+1));; esac
  printf '%-5s %-6s %-12s %s\n' "$3" "$1${SITE:+($SITE)}" "$2" "${4:0:160}"
}

judge() { # judge 번호 기준 "위반 목록"  → 비면 PASS, __ERR__가 있으면 ERROR, 그 밖은 FAIL
  if [[ "$3" == *__ERR__* ]]; then result "$1" "$2" ERROR "$(head -c 200 "$ERRF" | tr '\n' ' ')"
  elif [[ -z "${3// /}" ]]; then result "$1" "$2" PASS ""
  else result "$1" "$2" FAIL "$3"; fi
}

jqx() { # jq와 같지만 실패하면 __ERR__를 출력 (jq 오류가 빈 결과 = PASS로 보이지 않게)
  local o
  if o=$(jq "$@" 2>"$ERRF"); then printf '%s\n' "$o"; else echo "__ERR__"; fi
}

summary() {
  echo "PASS $pass / FAIL $fail / ERROR $err / SKIP $skip  → $JSONL"
}
