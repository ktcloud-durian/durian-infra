#!/usr/bin/env bash
# AWS 보안 점검 (보안 기준서 8.1 점검표). 조회 전용. Monitor EC2의 인스턴스 역할 권한으로 실행.
# 사용: OUT=결과폴더 [NAME=durian] [REGION=ap-northeast-2] [ADMINS="관리자 이름들"] [KEY_USERS="키 허용 사용자"] \
#       [STATE_BUCKET=버킷] [GLOBAL=true] bash aws.sh
# 자동으로 못 보는 항목(1~6·13·16~18·23·24·27)은 보안 기준서대로 직접 확인함.
set -uo pipefail
export CLOUD_NAME=aws
REGION=${REGION:-ap-northeast-2}
NAME=${NAME:-durian}
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

q() { # 성공하면 출력, 실패하면 __ERR__ (리전은 -r 로 바꿀 수 있음)
  local r="$REGION" o
  if [[ "${1:-}" == -r ]]; then r=$2; shift 2; fi
  if o=$(aws --region "$r" ${ENDPOINT:+--endpoint-url "$ENDPOINT"} "$@" 2>"$ERRF"); then printf '%s' "$o"
  else echo "__ERR__"; fi
}
oneline() { tr '\t\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//'; }

# ---------- 14 인터넷에 열린 인바운드 규칙 (ALB 보안그룹의 80·443만 예외, EX-01) ----------
alb_sgs=$(q elbv2 describe-load-balancers --query 'LoadBalancers[?Scheme!=`internal`].SecurityGroups[]' --output text)
[[ "$alb_sgs" == __ERR__ ]] && alb_sgs=""
r=$(q ec2 describe-security-group-rules \
  --query 'SecurityGroupRules[?IsEgress==`false` && (CidrIpv4==`0.0.0.0/0` || CidrIpv6==`::/0`)].[GroupId,SecurityGroupRuleId,IpProtocol,FromPort,ToPort]' --output text)
if [[ "$r" != __ERR__ ]]; then
  r=$(awk -v albs=" $alb_sgs " 'NF { alb = index(albs, " " $1 " ") > 0
        if (alb && $3 == "tcp" && $4 == $5 && ($4 == 80 || $4 == 443)) next
        printf "%s:%s:%s-%s ", $1, $2, $4, $5 }' <<<"$r")
fi
judge 14 NET-01·02 "$r"

# ---------- 15 VPC 기본 보안그룹은 규칙 0개 ----------
judge 15 NET-03 "$(q ec2 describe-security-groups --filters Name=group-name,Values=default \
  --query 'SecurityGroups[?length(IpPermissions)>`0` || length(IpPermissionsEgress)>`0`].GroupId' --output text | oneline)"

# ---------- 12·21a 실행 중 EC2: 인스턴스 프로파일, IMDSv2 ----------
inst=$(q ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId, MetadataOptions.HttpTokens, IamInstanceProfile.Arn]' --output text)
if [[ "$inst" == __ERR__ ]]; then judge 12 IAM-06 __ERR__; judge 21a SRV-01 __ERR__
else
  judge 12 IAM-06 "$(awk 'NF && ($3 == "" || $3 == "None") {printf "%s ", $1}' <<<"$inst")"
  judge 21a SRV-01 "$(awk 'NF && $2 != "required" {printf "%s ", $1}' <<<"$inst")"
fi

# ---------- 21b EBS 기본 암호화, 21c 계정 S3 퍼블릭 차단 ----------
e=$(q ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault --output text)
[[ "$e" == True ]] && e=""; judge 21b SRV-02 "${e:+EbsEncryptionByDefault=$e}"
acct=$(q sts get-caller-identity --query Account --output text)
if [[ "$acct" == __ERR__ ]]; then judge 21c DAT-02 __ERR__
else
  p=$(q s3control get-public-access-block --account-id "$acct" \
        --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text)
  if [[ "$p" == __ERR__ ]] && grep -q NoSuchPublicAccessBlockConfiguration "$ERRF"; then result 21c DAT-02 FAIL "계정 S3 퍼블릭 차단 설정 없음"
  elif [[ "$p" == __ERR__ ]]; then judge 21c DAT-02 __ERR__
  else [[ "$(oneline <<<"$p")" == "True True True True" ]] && judge 21c DAT-02 "" || judge 21c DAT-02 "꺼진 항목 있음: $(oneline <<<"$p")"; fi
fi

# ---------- 10 IAM 비밀번호 정책 14자 이상 (정책이 없으면 NoSuchEntity → 위반) ----------
l=$(q iam get-account-password-policy --query PasswordPolicy.MinimumPasswordLength --output text)
if [[ "$l" == __ERR__ ]] && grep -q NoSuchEntity "$ERRF"; then result 10 IAM-03 FAIL "비밀번호 정책 없음"
elif [[ "$l" == __ERR__ ]]; then judge 10 IAM-03 __ERR__
elif (( l >= 14 )); then result 10 IAM-03 PASS "최소 $l자"
else result 10 IAM-03 FAIL "최소 길이 $l"; fi

# ---------- 7 관리자 정책이 붙은 사용자·그룹·역할 중 승인 명단(ADMINS)에 없는 것 ----------
a=$(q iam list-entities-for-policy --policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
    --query '[PolicyUsers[].UserName, PolicyGroups[].GroupName, PolicyRoles[].RoleName][]' --output text)
if [[ "$a" != __ERR__ ]]; then
  a=$(comm -23 <(tr '\t ' '\n\n' <<<"$a" | grep . | sort -u) <(tr ' ' '\n' <<<"${ADMINS:-}" | grep . | sort -u) | oneline)
fi
judge 7 IAM-01·05 "$a"

# ---------- 8·9 credential report (만들기가 비동기라 COMPLETE까지 기다림) ----------
s=""; for _ in 1 2 3 4 5 6 7 8 9 10; do
  s=$(q iam generate-credential-report --query State --output text); [[ "$s" == COMPLETE ]] && break; sleep 3
done
c=$(q iam get-credential-report --query Content --output text)
if [[ "$c" == __ERR__ || "$s" != COMPLETE ]]; then
  for n in 8 9a 9b; do result $n IAM-02·03·05 ERROR "credential report 상태: $s"; done
else
  csv="$OUT/credential-report.csv"; ( umask 077; base64 -d <<<"$c" > "$csv" )
  # 9a 루트 키 없음 (4·9·14열: password_enabled, access_key_1_active, access_key_2_active)
  root=$(awk -F, 'NR>1 && $1=="<root_account>" {print $9" "$14}' "$csv")
  if [[ -z "$root" ]]; then result 9a IAM-02 ERROR "credential report에 루트 줄 없음"
  elif [[ "$root" == *true* ]]; then result 9a IAM-02 FAIL "루트 액세스 키가 켜져 있음"
  else result 9a IAM-02 PASS ""; fi
  # 9b 콘솔 비밀번호가 있는데 MFA 없는 사용자
  judge 9b IAM-03 "$(awk -F, 'NR>1 && $1!="<root_account>" && $4=="true" && $8=="false" {printf "%s ", $1}' "$csv")"
  # 8 켜진 키가 90일 넘었거나, 키 허용 명단(KEY_USERS) 밖 사용자에게 켜진 키가 있음
  now=$(date -u +%s)
  judge 8 IAM-05·07 "$(awk -F, -v now="$now" -v allow=" ${KEY_USERS:-} " '
    function age(t,  cmd, s) { if (t == "N/A" || t == "") return 0
      cmd = "date -u -d \"" t "\" +%s"; cmd | getline s; close(cmd); return int((now - s) / 86400) }
    NR>1 && $1!="<root_account>" {
      for (k = 0; k < 2; k++) { act = $(9 + k*5); rot = $(10 + k*5)
        if (act != "true") continue
        d = age(rot)
        if (d > 90) printf "%s:키%d(%d일) ", $1, k+1, d
        else if (allow != "  " && index(allow, " " $1 " ") == 0) printf "%s:키%d(허용 명단 밖) ", $1, k+1 } }' "$csv")"
fi

# ---------- 11 GitHub OIDC 역할 신뢰 조건 ----------
# 쓰기 역할(이름에 apply·deploy)은 environment나 main 브랜치만, 그 밖(읽기 plan 역할)은 pull_request도 허용.
# sub 조건이 없거나 repo 부분·끝이 '*'로 열려 있으면 위반
roles=$(q iam list-roles --output json)
if [[ "$roles" == __ERR__ ]]; then judge 11 IAM-04 __ERR__
else
  judge 11 IAM-04 "$(jqx -r '
    .Roles[] | . as $r
    | [.AssumeRolePolicyDocument.Statement[]?
       | select((.Principal.Federated // "" | tostring) | test("token.actions.githubusercontent.com"))] as $st
    | select($st | length > 0)
    | ([$st[] | .Condition // {} | to_entries[] | .value["token.actions.githubusercontent.com:sub"] // empty
        | if type == "array" then .[] else . end]) as $subs
    | ($r.RoleName | test("apply|deploy"; "i")) as $write
    | if ($subs | length) == 0 then "\($r.RoleName):sub조건없음"
      else $subs[]
        | select(
            (test("^repo:[^/]*\\*") or test(":\\*$") or test("^\\*$"))
            or ($write and (test(":environment:[^*]+$") or test(":ref:refs/heads/main$") | not))
            or (($write | not) and (test(":environment:[^*]+$") or test(":ref:refs/heads/main$") or test(":pull_request$") | not)))
        | "\($r.RoleName):\(sub("^repo:[^/]*/"; "repo:*/"))"
      end' <<<"$roles" | oneline)"
fi

# ---------- 19 ALB: 443은 HTTPS, 80은 443 리디렉션만, 그 밖 포트 없음 ----------
lbs=$(q elbv2 describe-load-balancers --query 'LoadBalancers[?Scheme!=`internal` && Type==`application`].LoadBalancerArn' --output text)
if [[ "$lbs" == __ERR__ ]]; then judge 19 DAT-01 __ERR__
else
  v=""
  for lb in $lbs; do
    n=${lb##*:loadbalancer/app/}; n=${n%%/*}   # ARN 대신 ALB 이름만 남김 (계정 ID 가림)
    l=$(q elbv2 describe-listeners --load-balancer-arn "$lb" --output json)
    [[ "$l" == __ERR__ ]] && { v+="__ERR__"; break; }
    v+=$(jqx -r --arg n "$n" '.Listeners[]
      | if .Port == 443 then (if .Protocol == "HTTPS" then empty else "\($n):443=\(.Protocol)" end)
        elif .Port == 80 then (if (.DefaultActions | length) == 1 and .DefaultActions[0].Type == "redirect"
                                  and .DefaultActions[0].RedirectConfig.Protocol == "HTTPS"
                                  and (.DefaultActions[0].RedirectConfig.Port == "443" or .DefaultActions[0].RedirectConfig.Port == "#{port}")
                               then empty else "\($n):80=리디렉션아님" end)
        else "\($n):\(.Port)포트" end' <<<"$l" | oneline)" "
  done
  judge 19 DAT-01 "$v"
fi

# ---------- 20 공개된 AMI·스냅샷 ----------
im=$(q ec2 describe-images --owners self --filters Name=is-public,Values=true --query 'Images[].ImageId' --output text)
sn=$(q ec2 describe-snapshots --owner-ids self --restorable-by-user-ids all --query 'Snapshots[].SnapshotId' --output text)
judge 20 DAT-06 "$(oneline <<<"$im $sn")"

# ---------- 22 트레일 로깅, ECR 태그 고정, 상태 버킷 버저닝 ----------
g=$(q cloudtrail get-trail-status --name "${TRAIL:-$NAME-trail}" --query IsLogging --output text)
if [[ "$g" == __ERR__ ]] && grep -q TrailNotFound "$ERRF"; then result 22a LOG-01 FAIL "트레일 없음 (${TRAIL:-$NAME-trail})"
else [[ "$g" == True ]] && g=""; judge 22a LOG-01 "${g:+IsLogging=$g}"; fi
judge 22b PIP-06 "$(q ecr describe-repositories --query 'repositories[?imageTagMutability!=`IMMUTABLE`].repositoryName' --output text | oneline)"
if [[ "$acct" == __ERR__ ]]; then judge 22c DAT-03 __ERR__
else
  b=$(q s3api get-bucket-versioning --bucket "${STATE_BUCKET:-$NAME-tfstate-$acct}" --query Status --output text)
  [[ "$b" == Enabled ]] && b=""; judge 22c DAT-03 "${b:+Versioning=$b}"
fi
unset acct

# ---------- 25 탐지·자동 대응 ----------
rules=$(q events list-rules --name-prefix "$NAME-" --query 'Rules[].[Name,State]' --output text)
if [[ "$rules" == __ERR__ ]]; then judge 25a LOG-05·06 __ERR__
else
  m=""; for want in sg-ingress-change guardduty-finding cloudtrail-tamper; do
    st=$(awk -v n="$NAME-$want" '$1 == n {print $2}' <<<"$rules")
    [[ "$st" == ENABLED ]] || m+="$NAME-$want(${st:-없음}) "
  done
  judge 25a LOG-05·06 "$m"
fi
det=$(q guardduty list-detectors --query 'DetectorIds[0]' --output text)
if [[ "$det" == __ERR__ ]]; then judge 25b LOG-05 __ERR__
elif [[ -z "$det" || "$det" == None ]]; then result 25b LOG-05 FAIL "GuardDuty 탐지기 없음"
else st=$(q guardduty get-detector --detector-id "$det" --query Status --output text)
     [[ "$st" == ENABLED ]] && st=""; judge 25b LOG-05 "${st:+Status=$st}"; fi
unset det
errs=$(q cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
  --dimensions Name=FunctionName,Value="$NAME-sec-responder" --statistics Sum --period 86400 \
  --start-time "$(date -u -d '-7 days' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --query 'sum(Datapoints[].Sum)' --output text)
if [[ "$errs" == __ERR__ ]]; then judge 25c LOG-06 __ERR__
elif [[ "$errs" =~ ^(0|0\.0|None)?$ ]]; then result 25c LOG-06 PASS "최근 7일 오류 0"
else result 25c LOG-06 FAIL "최근 7일 Lambda 오류 ${errs%.0}건"; fi
if [[ "${GLOBAL:-false}" == true ]]; then
  g=$(q -r us-east-1 events list-rules --name-prefix "$NAME-" --query 'Rules[].[Name,State]' --output text)
  if [[ "$g" == __ERR__ ]]; then judge 25d LOG-07 __ERR__
  else
    m=""; for want in iam-change root-login; do
      st=$(awk -v n="$NAME-$want" '$1 == n {print $2}' <<<"$g"); [[ "$st" == ENABLED ]] || m+="$NAME-$want(${st:-없음}) "
    done
    judge 25d LOG-07 "$m"
  fi
else
  result 25d LOG-07 SKIP "us-east-1 탐지 꺼짐. 켜면 GLOBAL=true로 점검"
fi

# ---------- 26 모니터링 스택 노출 ----------
# 26a Monitor EC2 보안그룹 인바운드 0개
ms=$(q ec2 describe-instances --filters Name=tag:Role,Values=monitor Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text)
if [[ "$ms" == __ERR__ ]]; then judge 26a NET-06 __ERR__
elif [[ -z "${ms// /}" ]]; then result 26a NET-06 SKIP "실행 중인 Monitor EC2 없음"
else
  ids=$(oneline <<<"$ms" | tr ' ' ',')
  judge 26a NET-06 "$(q ec2 describe-security-group-rules --filters Name=group-id,Values="$ids" \
    --query 'SecurityGroupRules[?IsEgress==`false`].[GroupId,SecurityGroupRuleId]' --output text | awk 'NF {printf "%s:%s ", $1, $2}')"
fi
# 26b·26c 이 서버가 Monitor일 때만: 3000·9090·9093은 127.0.0.1에만, Grafana 기본 비밀번호(admin/admin) 실패
if [[ -f /opt/monitoring/docker-compose.yml ]]; then
  if ! command -v ss >/dev/null; then result 26b NET-06 ERROR "ss 명령 없음"
  else
    judge 26b NET-06 "$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(3000|9090|9093)$' | grep -vE '^(127\.0\.0\.1|\[::1\]):' | oneline)"
  fi
  du="admin"   # Grafana 출고 기본 계정 (admin/admin). 이게 거부돼야 PASS
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -u "$du:$du" http://127.0.0.1:3000/api/user || echo 000)
  case "$code" in
    401) result 26c NET-06 PASS "기본 비밀번호 거부됨" ;;
    200) result 26c NET-06 FAIL "Grafana가 admin/admin으로 로그인됨" ;;
    *)   result 26c NET-06 ERROR "Grafana 응답 코드 $code" ;;
  esac
fi

summary
