#!/usr/bin/env bash
# OS-R2(점검표 16) 기준 목록 만들기: 지금 OpenStack 보안그룹 규칙을 '승인된 상태'로 저장함.
# 그 뒤로는 점검기가 이 목록에 없는 규칙(콘솔에서 새로 만든 규칙)을 FAIL로 찾음 (NET-05, LOG-02·03).
# OpenStack 보안그룹은 아직 Terraform으로 관리하지 않아서, 사람이 방화벽 정책 정의서 5번과 맞는지 확인한 뒤의 상태를 기준으로 씀.
# 사용 (Monitor EC2, 조회 전용 reader 계정):
#   sudo bash os-baseline.sh --show a      규칙을 표로 보기 (정의서 5번과 비교)
#   sudo bash os-baseline.sh a [b]         확인한 상태를 기준으로 저장 → /etc/durian-check/managed-rule-ids-<사이트>.txt (600)
# 정의서대로 규칙을 바꾸면(PR → 보안 승인) 다시 --show로 보고 저장함.
set -euo pipefail
CONF=${CONF:-/etc/durian-check/config.env}
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
export OS_CLIENT_CONFIG_FILE=${OS_CLIENT_CONFIG_FILE:-/etc/durian-check/clouds.yaml}
DIR=${MANAGED_IDS_DIR:-/etc/durian-check}
command -v openstack >/dev/null || { echo "openstack 명령 없음 (setup.sh가 설치함)"; exit 1; }
command -v jq >/dev/null || { echo "jq 없음"; exit 1; }

show=false
if [[ "${1:-}" == --show ]]; then show=true; shift; fi
[[ $# -ge 1 ]] || { sed -n '5,7p' "$0"; exit 1; }

# 점검기(openstack.sh OS-R2)와 같은 기준으로 거름: default 그룹과, 새 그룹마다 Neutron이 자동으로 만드는 원격 없는 egress는 뺌
FILTER='. as $r | select(($dflt | index(" " + $r["Security Group"] + " ")) | not)
  | select(.Direction=="ingress" or .["IP Range"]!=null or .["Remote Security Group"]!=null)'

for SITE in "$@"; do
  P="durian-$SITE"
  G=$(openstack --os-cloud "$P" security group list -f json)
  A=$(openstack --os-cloud "$P" security group rule list -f json)
  DEF=$(jq -r '[.[] | select(.Name=="default") | .ID] | join(" ")' <<<"$G")
  if $show; then
    echo "== 사이트 $SITE"
    SHOW='($g | map({(.ID): .Name}) | add) as $name
      | [.[] | '"$FILTER"'
         | [($name[.["Security Group"]] // .["Security Group"][0:8]), .Direction, (.["IP Protocol"] // "any"),
            ((.["Port Range"] // "") | if . == "" then "전체" else . end),
            (.["IP Range"] // (($name[.["Remote Security Group"]] // "") | if . == "" then "-" else "그룹:" + . end)),
            .ID[0:8]]]
      | sort[] | @tsv'
    { printf '보안그룹\t방향\t프로토콜\t포트\t상대\tID\n'; jq -r --arg dflt " $DEF " --argjson g "$G" "$SHOW" <<<"$A"; } |
      awk -F'\t' '{printf "%-22s %-8s %-6s %-12s %-22s %s\n", $1, $2, $3, $4, $5, $6}'
    continue
  fi
  out="$DIR/managed-rule-ids-$SITE.txt"
  install -d -m 700 "$DIR"
  ( umask 077; jq -r --arg dflt " $DEF " ".[] | $FILTER | .ID" <<<"$A" | sort -u > "$out.tmp" )
  mv -f "$out.tmp" "$out"; chmod 600 "$out"
  echo "저장: $out ($(wc -l < "$out")개 규칙). 다음 점검부터 이 목록 밖 규칙은 OS-R2 FAIL"
done
