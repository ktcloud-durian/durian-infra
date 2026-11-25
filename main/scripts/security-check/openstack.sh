#!/usr/bin/env bash
# OpenStack 보안 점검 (보안 기준서 8.1 점검표 + 설계서 11번 OS-A1~A3·OS-R1~R3). reader 계정, Tailscale 경유.
# 사용: OUT=결과폴더 OS_SITES="a b" [OS_CLIENT_CONFIG_FILE=/etc/durian-check/clouds.yaml] bash openstack.sh
# clouds.yaml 이름 규칙: durian-<사이트>     = 팀 프로젝트 reader (필수)
#                        durian-<사이트>-sys = system reader (있으면 계정 항목 OS-A1~A3도 점검, 없으면 SKIP)
# 설정(config.env): TEAM_USERS, APPROVED_ADMINS, FIP_ALLOW_SERVERS, DB_NAME_PATTERN, MANAGED_IDS_DIR
set -uo pipefail
export CLOUD_NAME=openstack
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CFG=${OS_CLIENT_CONFIG_FILE:-$HOME/.config/openstack/clouds.yaml}
export OS_CLIENT_CONFIG_FILE="$CFG"
DB_NAME_PATTERN=${DB_NAME_PATTERN:-db}

q() { # q 클라우드 명령...  → JSON, 실패하면 __ERR__
  local o
  if o=$(openstack --os-cloud "$1" "${@:2}" -f json 2>"$ERRF"); then printf '%s' "$o"; else echo "__ERR__"; fi
}
jqf() { [[ "$1" == __ERR__ ]] && echo __ERR__ || jqx -r "$2" <<<"$1" | tr '\n' ' ' | sed 's/ *$//'; }
has_cloud() { grep -qE "^[[:space:]]+$1:[[:space:]]*$" "$CFG" 2>/dev/null; }
all_items() { for n in OS-R1 OS-R2 OS-R3 OS-20 OS-IAM04 OS-A1 OS-A2 OS-A3; do result "$n" "$1" ERROR "$2"; done; }

if ! command -v openstack >/dev/null; then
  SITE=""; result OS-00 setup SKIP "openstack 명령 없음 (pip install python-openstackclient)"; summary; exit 0
fi
if [[ ! -f "$CFG" ]]; then
  SITE=""; result OS-00 setup SKIP "자격 증명 파일 없음 ($CFG)"; summary; exit 0
fi
perm=$(stat -c %a "$CFG")
[[ "$perm" == 600 || "$perm" == 400 ]] || { SITE=""; result OS-00 SEC-01 FAIL "자격 증명 파일 권한 $perm (600이어야 함)"; }

for SITE in ${OS_SITES:-a}; do
  P="durian-$SITE"; S="durian-$SITE-sys"
  if ! has_cloud "$P"; then result OS-00 setup SKIP "clouds.yaml에 $P 없음"; continue; fi
  if ! openstack --os-cloud "$P" token issue -f value -c expires >/dev/null 2>"$ERRF"; then
    all_items 로그인 "reader 로그인 실패: $(head -c 150 "$ERRF" | tr '\n' ' ')"; continue
  fi

  # OS-R1 (점검표 14) 인터넷에 열린 인바운드: IP Range가 0.0.0.0/0·::/0이거나, 원격 주소·그룹이 모두 비어 있음(=모든 곳)
  R=$(q "$P" security group rule list --ingress)
  judge OS-R1 NET-01·02 "$(jqf "$R" '.[] | select((.["IP Range"]=="0.0.0.0/0" or .["IP Range"]=="::/0") or
      (.["IP Range"]==null and .["Remote Security Group"]==null and (.["Remote Address Group"]//null)==null))
    | "\(.["Security Group"][0:8]):\(.ID[0:8]):\(.["Port Range"] // "전체")"')"

  # OS-R2 (점검표 16) Terraform 관리 목록 밖 규칙. 목록 파일이 있을 때만 (드리프트 job이 terraform show -json에서 뽑음)
  M="${MANAGED_IDS_DIR:-/etc/durian-check}/managed-rule-ids-$SITE.txt"
  if [[ ! -f "$M" ]]; then result OS-R2 NET-05 SKIP "관리 규칙 ID 목록 없음 ($M)"
  else
    A=$(q "$P" security group rule list); G=$(q "$P" security group list)
    if [[ "$A" == __ERR__ || "$G" == __ERR__ ]]; then judge OS-R2 NET-05 __ERR__
    else
      DEF=$(jqx -r '[.[] | select(.Name=="default") | .ID] | join(" ")' <<<"$G")
      # 새 보안그룹마다 Neutron이 자동으로 만드는 기본 egress(원격 없음)와 default 그룹은 Terraform이 모르므로 거름
      judge OS-R2 NET-05 "$(jqx -r --arg dflt " $DEF " '.[] | . as $r | select(($dflt | index(" " + $r["Security Group"] + " ")) | not)
          | select(.Direction=="ingress" or .["IP Range"]!=null or .["Remote Security Group"]!=null) | .ID' <<<"$A" |
        sort | comm -23 - <(sort "$M") | cut -c1-8 | tr '\n' ' ')"
    fi
  fi

  # OS-R3 (점검표 17) Floating IP가 붙은 서버: 허용 목록(FIP_ALLOW_SERVERS) 밖이거나 DB 서버면 위반. IP는 남기지 않고 서버 이름만
  F=$(q "$P" floating ip list); V=$(q "$P" server list)
  if [[ "$F" == __ERR__ || "$V" == __ERR__ ]]; then judge OS-R3 NET-05 __ERR__
  else
    judge OS-R3 NET-05 "$(jqx -r --argjson f "$F" --arg allow " ${FIP_ALLOW_SERVERS:-} " --arg db "$DB_NAME_PATTERN" '
        [$f[] | select(.Port != null) | .["Floating IP Address"]] as $fips
      | .[] | . as $s | (.Networks | tostring) as $n
      | select(any($fips[]; . as $ip | $n | contains("\"" + $ip + "\"")))
      | select(($s.Name | test($db; "i")) or (($allow | index(" " + $s.Name + " ")) | not))
      | $s.Name' <<<"$V" | tr '\n' ' ')"
  fi

  # OS-20 (점검표 20) 백업 이미지가 공개·공유·커뮤니티로 열려 있음
  imgs=""; for v in --public --shared --community; do
    I=$(q "$P" image list $v); [[ "$I" == __ERR__ ]] && { imgs=__ERR__; break; }
    imgs+="$(jqx -r '.[] | select(.Name | test("backup|dump|db"; "i")) | .Name' <<<"$I" | tr '\n' ' ')"
  done
  judge OS-20 DAT-06 "$imgs"

  # OS-IAM04 reader로 쓰기가 막히는지: 정기 점검은 조회만 하므로 여기서 쓰기를 시도하지 않음.
  # 쓰기 시험은 os-write-probe.sh를 사람이 따로 돌리고(보안그룹 만들기 → 403이어야 통과), 그 마지막 결과를 읽어 보여 줌
  PROBE=${PROBE_DIR:-/var/lib/durian-check}/write-probe-$SITE.json
  if [[ ! -s "$PROBE" ]]; then result OS-IAM04 IAM-04 SKIP "쓰기 시험 결과 없음 → sudo bash os-write-probe.sh $SITE"
  else
    pr=$(jqx -r '.result' <"$PROBE"); pd=$(jqx -r '"\(.date) 시험: \(.detail)"' <"$PROBE")
    age=$(( ( $(date +%s) - $(stat -c %Y "$PROBE") ) / 86400 ))
    if [[ "$pr" == __ERR__ || "$pd" == __ERR__ ]]; then result OS-IAM04 IAM-04 ERROR "쓰기 시험 결과 파일을 못 읽음 ($PROBE)"
    elif (( age > 7 )); then result OS-IAM04 IAM-04 SKIP "쓰기 시험이 ${age}일 전 결과 (7일 넘음) → 다시 실행. $pd"
    else result OS-IAM04 IAM-04 "$pr" "$pd"; fi
  fi

  # OS-A1~A3 계정 항목 (system reader가 있을 때만)
  if ! has_cloud "$S"; then
    for n in OS-A1 OS-A2 OS-A3; do result $n IAM-01·05 SKIP "clouds.yaml에 $S(system reader) 없음"; done
    continue
  fi
  U=$(q "$S" user list)
  # OS-A1 (점검표 6) 팀원·서비스 계정 명단(TEAM_USERS)에 없는 활성 계정
  judge OS-A1 IAM-01 "$(jqf "$U" '.[] | select(.Enabled != false) | .Name' | tr ' ' '\n' | grep . | sort -u |
    comm -23 - <(tr ' ' '\n' <<<"${TEAM_USERS:-}" | grep . | sort -u) | tr '\n' ' ')"
  # OS-A2 (점검표 7) admin 역할 배정 중 승인 명단(APPROVED_ADMINS)에 없는 사용자·그룹
  RA=$(q "$S" role assignment list --names --role admin)
  judge OS-A2 IAM-01·05 "$(jqf "$RA" '.[] | (if (.User // "") != "" then .User else (.Group // "") end) | sub("@.*"; "")' | tr ' ' '\n' | grep . | sort -u |
    comm -23 - <(tr ' ' '\n' <<<"${APPROVED_ADMINS:-}" | grep . | sort -u) | tr '\n' ' ')"
  # OS-A3 (점검표 8) 만료일 없는 Application Credential
  if [[ "$U" == __ERR__ ]]; then judge OS-A3 IAM-05 __ERR__
  else
    noexp=""; e=""
    while read -r uid uname; do
      [[ -z "$uid" ]] && continue
      C=$(q "$S" application credential list --user "$uid"); [[ "$C" == __ERR__ ]] && { e=1; continue; }
      noexp+=$(jqx -r --arg u "$uname" '.[] | select(.["Expires At"]==null or .["Expires At"]=="") | "\($u):\(.Name) "' <<<"$C")
    done < <(jq -r '.[] | "\(.ID) \(.Name)"' <<<"$U")
    [[ -n "$e" ]] && judge OS-A3 IAM-05 __ERR__ || judge OS-A3 IAM-05 "$noexp"
  fi
done
SITE=""
summary
