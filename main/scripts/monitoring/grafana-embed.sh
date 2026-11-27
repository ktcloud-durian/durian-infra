#!/usr/bin/env bash
# Grafana 임베드(iframe) 옵션 — 기본값은 꺼짐 (SOC 화면에 보안 관제 대시보드 패널을 넣기 위한 것)
# install.sh monitor 단계에서 부름. k3s User Data(16KiB 제한)에 install.sh가 통째로 들어가서 이 부분만 따로 둠.
# 두 변수가 모두 비어 있으면 install.sh가 이 파일을 부르지 않는다 → Grafana 설정은 이전과 완전히 같다
#   (allow_embedding 꺼짐 → X-Frame-Options: deny 유지, CSP 꺼짐, 쿠키 기본값, docker-compose.yml 동일)
#
# - GRAFANA_EMBED_ORIGIN (기본 빈 값): Grafana 패널을 iframe으로 넣을 화면의 주소 하나 (예: https://soc.example.com)
#     https://로 시작하는 origin 하나만 허용 (경로·쉼표·공백·와일드카드·http:// 불가). 틀리면 설치 중단
#     값이 있으면: GF_SECURITY_ALLOW_EMBEDDING=true
#                  GF_SECURITY_CONTENT_SECURITY_POLICY=true, frame-ancestors는 'self' + 이 주소만 (클릭재킹 완화)
#                  GF_SECURITY_COOKIE_SAMESITE=none, GF_SECURITY_COOKIE_SECURE=true (iframe 안 로그인 쿠키용)
# - GRAFANA_ROOT_URL (기본 빈 값): 값이 있으면 GF_SERVER_ROOT_URL로 전달 (예: tailscale serve의 HTTPS 주소)
# - 익명 접근(GF_AUTH_ANONYMOUS_ENABLED)은 이 옵션과 관계없이 항상 "false" (NET-06). 임베드는 로그인(Viewer) 방식만
# - 켤 때 필요한 조건:
#     1) 보안 담당 승인 (보안 설정 변경)
#     2) SOC 화면에서 Grafana에 HTTPS로 접속할 수 있어야 함 (SameSite=None 쿠키는 Secure 필수 → http 주소로는
#        iframe 안 로그인이 안 됨). 보통 GRAFANA_ROOT_URL에 그 HTTPS 주소를 같이 넣는다
#     SSM 포트 포워딩(http://localhost:3000) 접속은 켠 뒤에도 쓸 수 있을 것으로 예상 (브라우저가 localhost를 보안 출처로 취급)
#
# 사용: bash grafana-embed.sh check    → 변수 형식 검사 (틀리면 이유 출력 후 exit 1)
#       bash grafana-embed.sh compose /opt/monitoring/docker-compose.yml
#                                      → grafana environment에 임베드 설정 줄을 넣는다
set -euo pipefail
origin="${GRAFANA_EMBED_ORIGIN:-}"; origin="${origin%/}"
root_url="${GRAFANA_ROOT_URL:-}"

case "${1:-}" in
  check)
    if [[ -n "$origin" && ! "$origin" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; then
      echo "ERROR: GRAFANA_EMBED_ORIGIN 형식 오류: https://로 시작하는 주소(origin) 하나만 허용 (예: https://soc.example.com)" >&2
      echo "       경로, 쉼표/공백으로 여러 개, 와일드카드(*), http:// 는 허용하지 않음 → 설치 중단" >&2
      exit 1
    fi
    if [[ -n "$root_url" && ! "$root_url" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
      echo "ERROR: GRAFANA_ROOT_URL 형식 오류: http(s)://호스트[:포트][/경로] 하나만 허용 → 설치 중단" >&2
      exit 1
    fi
    if [[ -n "$origin" ]]; then
      echo "  Grafana 임베드 켜짐: frame-ancestors 'self' $origin (익명 접근은 계속 꺼짐)"
      [[ "$root_url" == https://* ]] || echo "  WARN: GRAFANA_ROOT_URL이 HTTPS가 아님. SOC 화면 iframe 안 로그인은 Grafana가 HTTPS일 때만 동작"
    fi
    ;;
  compose)
    # 인자: install.sh가 만든 docker-compose.yml. grafana environment의 마지막 줄(GF_NEWS_NEWS_FEED_ENABLED) 뒤에 넣는다
    file="${2:?사용: $0 compose <docker-compose.yml>}"
    # check를 먼저 통과한 값만 쓴다 (형식이 틀리면 여기서도 중단)
    bash "${BASH_SOURCE[0]}" check >/dev/null
    anchor='      GF_NEWS_NEWS_FEED_ENABLED: "false"'
    if [[ $(grep -cxF -- "$anchor" "$file") != 1 ]]; then
      echo "ERROR: $file 에서 Grafana 환경 변수 위치를 찾지 못함 (install.sh compose 형식 변경?) → 설치 중단" >&2
      exit 1
    fi
    lines=""
    # CSP 템플릿은 Grafana v12.0.2 기본 템플릿 끝에 frame-ancestors만 더한 것.
    # $$는 compose에서 Grafana 변수($NONCE 등)를 그대로 넘기려는 표기
    if [[ -n "$origin" ]]; then
      lines=$(sed "s|__EMBED_ORIGIN__|${origin}|" <<'EOF'
      GF_SECURITY_ALLOW_EMBEDDING: "true"
      GF_SECURITY_CONTENT_SECURITY_POLICY: "true"
      GF_SECURITY_CONTENT_SECURITY_POLICY_TEMPLATE: "script-src 'self' 'unsafe-eval' 'unsafe-inline' 'strict-dynamic' $$NONCE;object-src 'none';font-src 'self';style-src 'self' 'unsafe-inline' blob:;img-src * data:;base-uri 'self';connect-src 'self' grafana.com ws://$$ROOT_PATH wss://$$ROOT_PATH;manifest-src 'self';media-src 'none';form-action 'self';frame-ancestors 'self' __EMBED_ORIGIN__;"
      GF_SECURITY_COOKIE_SAMESITE: "none"
      GF_SECURITY_COOKIE_SECURE: "true"
EOF
)
    fi
    if [[ -n "$root_url" ]]; then
      lines+="${lines:+$'\n'}$(printf '      GF_SERVER_ROOT_URL: "%s"' "$root_url")"
    fi
    [[ -n "$lines" ]] || exit 0
    tmp="$file.tmp.$$"
    INS="$lines" awk -v a="$anchor" '{ print } $0 == a { print ENVIRON["INS"] }' "$file" > "$tmp"
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
    ;;
  *) echo "사용: $0 check | compose <docker-compose.yml>" >&2; exit 2 ;;
esac
