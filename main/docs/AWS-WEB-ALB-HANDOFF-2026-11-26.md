# AWS 웹 서비스 구축 및 ALB·Route 53 배포 검토 (2026-11-26)

> 배포 준비 및 승인 요청용 기록입니다. 팀 승인 전 Merge 및 Apply를 진행하지 않습니다. 이 문서 추가 자체는 인프라 구성을 변경하지 않습니다.

## 1. 구축 및 검증 내역 (11/25~11/26)

- 기존 AWS A/C 독립 K3s 클러스터 및 Argo CD 기반 Bank Web 배포 구성 사용.
- Traefik HTTP NodePort 30080을 통한 SSM 포트 포워딩 웹 접속: A/C 성공.
- AWS A/C Web Pod에서 OpenStack A Core API의 `/health` HTTP 200 및 인증 없는 내부 API 요청 HTTP 401 확인.
- AWS Worker A/C 호스트에서 OpenStack A API Health Check 200 확인.
- OpenStack B API 연결: 초기 VPN 경로 미수신 및 Web Egress 미허용으로 연결 실패. A/C 클러스터 Web Egress에 B API(10.31.20.200/32 TCP 4000)를 임시 추가하고 Tailscale 경로 복구 후 11/26 16:55경 재검증 성공.
- AWS Master A/C에서 `10.31.20.200` 목적지의 `tailscale0` / table 52 경로 및 `k8s-worker-b` Peer 확인. 각 클러스터의 Web Pod에서 B API `/health` HTTP 200 및 인증 없는 `/internal/customers/1/summary` HTTP 401 확인.
- B API 통신 검증은 완료했으나 임시 NetworkPolicy의 GitOps 영구 반영, 전체 Pod/Worker 경로 및 자동 장애 전환은 별도 검증 필요.
- 로그인, 조회, 이체, DB 복제 및 자동 장애 전환은 본 검증 범위에 포함하지 않음.

## 2. DNS 및 TLS

- 가비아에서 교육용 데모 도메인 `durian-bank.xyz` 등록.
- Route 53 Public Hosted Zone 생성, 가비아 네임서버를 Route 53으로 위임.
- 서울 리전 ACM 공개 인증서 요청 (DNS 검증, 내보내기 비활성화).
- 검증 CNAME 등록: Route 53 변경 상태 INSYNC, 공개 NS/CNAME 조회 성공, ACM ISSUED 확인.
- Hosted Zone과 인증서는 CLI/콘솔에서 사전 생성한 리소스이며, 이 PR에서 신규 Terraform 관리 리소스로 가져오지 않음. 인증서 갱신에 필요한 CNAME 유지.

## 3. ALB 배포 계획

기존 main의 `alb.tf`, `alb-sg.tf`, `sg-roles.tf`, `k3s-worker.tf`, `route53-web.tf`를 사용.

- 인터넷 연결 ALB, A/C Public Subnet.
- HTTPS 443 (ACM), HTTP 80 → HTTPS 301.
- Target Group: Instance 유형, HTTP 30080, Health Check /health.
- Worker A/C ASG → 동일 Target Group 연결.
- Worker NodePort 접근은 ALB SG에서만 허용하는 신규 규칙.
- 기존 Hosted Zone에 ALB 대상 A Alias 생성 예정.

로컬 Plan (main 기준 커밋 `156ed57`, 공개 접근 정책 변경 전):

```text
Plan: 11 to add, 5 to change, 0 to destroy.
```

신규 11개: ALB, Target Group, Listener 2개, Alias, ALB/Worker 보안그룹 규칙 5개, Terraform 배포 조건 가드.

변경 5개: Worker A/C ASG Target Group 연결, Worker A/C Launch Template 업데이트, Monitor IAM Policy 업데이트. 기존 리소스 삭제/교체 계획 없음. 당시 두 ASG 모두 Min/Desired/Max=1, Worker InService 확인. Launch Template 변경은 신규 버전에 영향을 주므로 팀 검토 필요.

## 4. 배포 전 남은 설정

현재 Workflow에는 ALB 활성화 변수만 전달됨. 아래 세 변수의 GitHub Actions 연동은 별도 코드 변경 필요.

- `TF_VAR_aws_alb_certificate_arn`
- `TF_VAR_aws_web_domain_name`
- `TF_VAR_aws_web_route53_zone_id`

실제 ARN 및 Zone ID는 Actions Variables 등 팀 승인된 설정으로 전달하고 로컬 백업, 개인 IP, 상태 파일, Plan 전문은 커밋하지 않음. ALB 활성화 및 Apply 승인 스위치는 팀 승인 전 활성화하지 않음.

현재 ALB 80/443 CIDR은 0.0.0.0/0. 최초 테스트는 승인된 팀원 IP로 제한하는 방향 검토 필요. 외부 공개 전 로그인/금융 기능과 데모 데이터·자격증명 점검 필요. 이 문서는 보안그룹 코드를 수정하지 않음.

## 5. 배포 및 검증 체크리스트

- [x] SSM 웹 접속 및 OpenStack A API 연결 검증
- [x] AWS A/C Web Pod → OpenStack B API 200/401 응답 검증
- [x] 도메인, Route 53 위임 및 ACM 발급
- [x] 로컬 ALB Terraform Plan
- [ ] Actions 변수 전달 및 접근 정책 코드 정리
- [ ] 최신 main 기준 CI Plan 및 보안 검사
- [ ] 팀 리뷰 및 배포 승인
- [ ] 승인된 방식으로 Terraform Apply (다른 팀원 배포와 중복 금지)
- [ ] ALB Target Group A/C Healthy 확인
- [ ] Route 53 Alias 및 HTTPS 접속, HTTP 리다이렉트 확인
- [ ] 로그인/금융 기능 별도 검증
- [ ] B API Egress 정책 GitOps 영구 반영 및 재검증

## 6. 비용 및 운영

ALB는 Worker/EC2 중지와 별개로 사용 요금이 발생할 수 있으므로 시연 외 운영 여부 및 제거 계획을 팀과 협의. 정리 시 전체 terraform destroy 대신 ALB 관련 변경 범위를 검토한 Plan으로 진행하고, DNS 검증 CNAME과 Hosted Zone, ACM 인증서는 후속 사용 여부에 맞춰 유지.

## 7. 리뷰 요청

- ALB 80/443 최초 접근 범위 및 공개 기준
- ASG 및 Launch Template, Monitor IAM 변경 영향
- GitHub Actions 변수 전달 및 배포 승인 절차
- ALB 생성 및 운영 비용 승인

ALB Apply, Target Group A/C Healthy 및 HTTPS 외부 접속 검증은 2026년 11월 26일 완료했습니다. 최신 결과는 8절을 참고합니다.

## 8. 11/26 배포 완료 후 검증 기록

위 1~7절은 배포 전 검토 이력이며, 현재 상태는 이 절을 기준으로 합니다.

### 실제 배포 결과

기존 main의 ALB 및 Route 53 Terraform 리소스를 사용하여 로컬 저장 Plan을 적용했습니다. 배포 결과:

```text
Apply complete! Resources: 11 added, 5 changed, 0 destroyed.
```

- ALB, Target Group, HTTP/HTTPS Listener, A Alias, 보안그룹 규칙 및 배포 가드 생성 완료.
- Worker A/C ASG의 Target Group 연결, Launch Template 업데이트, Monitor IAM Policy 업데이트 완료.
- ALB 생성 약 2분 32초, Route 53 Alias 생성 약 32초 (Terraform 출력 기준).
- ALB는 인터넷 연결형이며 80/443 접근 범위는 기존 전체 공개 정책 그대로입니다. 보안 담당자의 공개 범위 재검토가 필요합니다.

### 실제 접속 및 보안 검증

11/26 20:26 KST경 외부 접속 테스트 기준:

| 검사 | 결과 |
|---|---|
| Worker A / C Target Group, HTTP 30080 | 2/2 healthy |
| HTTP 도메인 요청 | 301, HTTPS 443으로 이동 |
| HTTPS /health | 200, {"status":"ok"} |
| 외부 브라우저 웹 페이지 | 정상 표시 |
| HSTS / CSP 응답 헤더 | 존재 확인 |

브라우저 및 curl에서 실제 도메인 접속을 확인했습니다. TLS 인증서 검증을 생략하는 옵션은 사용하지 않았습니다. 이는 웹 서비스 가용성 검증이며 DB 읽기/쓰기, 사용자 인증 성공, 장애 전환을 입증하는 것은 아닙니다.

### 하이브리드 연결 정책 영구 반영 및 복구

- [GitOps #9](https://github.com/ktcloud-durian/cicd-platform-gitops/pull/9): AWS Web Egress에 A/B API TCP 4000 허용, DNS 및 기본 차단 유지. main 병합 확인.
- [ACL #16](https://github.com/ktcloud-durian/tailscale-acl/pull/16): A/B Core API 별칭 및 B 경로 자동 승인 추가. 적용 후 Master의 A/B 경로가 기본 NIC로 돌아가 API Timeout 발생.
- [ACL #17](https://github.com/ktcloud-durian/tailscale-acl/pull/17): Master/Worker → A/B Core API TCP 4000 허용 및 Master 허용 테스트 추가. DB/SSH 차단 정책 유지. main 자동 ACL 적용 성공.
- AWS Master A/C에서 A/B 목적지 모두 tailscale0, table 52 경로 복구 및 각 클러스터 Web Pod의 A/B /health 200 확인.
- 인증 없는 내부 API 요청 401은 기존 A/B 양쪽 검증과 복구 후 C 클러스터의 A/B 재검증이 성공했습니다. 복구 후 A의 401 결과는 접속 노드가 명시된 로그로 추가 확인 권장.
- C 클러스터 실제 NetworkPolicy에 A/B 주소 모두 존재. A/C Argo CD Sync 상태 및 전체 Pod별 검증은 별도 확인 대상.

### 배포 설정 일치 (이번 PR의 Workflow 변경)

`.github/workflows/terraform.yml`의 공통 env에 아래 5개 Terraform 변수 전달을 추가합니다. Drift Workflow에도 같은 ALB 변수 전달을 반영합니다. 기존 OIDC, 승인 게이트, 보안 검사 및 Apply 조건은 유지합니다.

| Actions Repository Variable / Secret | 배포 유지에 필요한 값 |
|---|---|
| TF_APPLY_ENABLED | false 유지 |
| TF_VAR_AWS_ALB_ENABLED (Repository Variable) | true (팀 승인 후) |
| TF_VAR_AWS_ALB_PUBLIC_ACCESS (Repository Variable) | false (검증·평상시 제한 모드), true는 승인된 시연 기간에만 |
| TF_VAR_AWS_ALB_ALLOWED_CIDRS (Repository Secret) | 승인된 팀원 IPv4 /32 목록 (JSON 배열, 실제 값 비공개) |
| TF_VAR_AWS_ALB_CERTIFICATE_ARN (Repository Secret) | 서울 리전의 발급 완료 ACM 인증서 ARN |
| TF_VAR_AWS_WEB_DOMAIN_NAME (Repository Variable) | durian-bank.xyz |
| TF_VAR_AWS_WEB_ROUTE53_ZONE_ID (Repository Variable) | 기존 Public Hosted Zone ID |

실제 변수값은 이번 PR이 변경하지 않습니다. 마지막 확인 당시 ALB 활성화 변수는 false이고 ACM/Route53 변수가 없었습니다. 현재 값은 관리자가 재확인해야 합니다. ALB가 이미 State에 존재하므로 false 설정으로 CI Plan을 수행하면 ALB 관련 삭제가 계획될 수 있습니다. Apply 금지 상태에서 팀과 변수 일치 작업을 진행하고 PR Plan을 재실행하여 의도하지 않은 삭제/교체가 없는지 확인해야 합니다. 로컬 terraform.tfvars에도 같은 설정을 안전하게 유지하고 비밀값, 계정 식별자가 포함된 전체 출력 및 상태 파일은 저장소에 커밋하지 않습니다.

### PR #30 리뷰 반영 (11/26)

- 최초 CI Plan: `0 to add, 4 to change, 11 to destroy`. 실제 Apply/Destroy는 실행하지 않았습니다.
- 최초 Plan 로그에서 ACM ARN 환경변수 값이 비어 있어 실제 ARN 노출은 확인되지 않았습니다. 환경변수 값 자체가 로그에 표시되는 구조이므로 계정 ID 마스킹 원칙에 따라 ACM ARN은 Repository Secret으로 변경했습니다.
- 도메인 및 Hosted Zone은 Repository Variables, ACM ARN은 Repository Secret으로 등록된 화면을 확인했습니다. Secret 실제 값은 화면에서 확인할 수 없으므로 최종 Plan에서 검증합니다.
- Workflow의 인증서 참조를 `secrets.TF_VAR_AWS_ALB_CERTIFICATE_ARN`으로 변경했습니다. 동일 저장소 PR 기준이며 fork PR에는 Secret이 전달되지 않습니다.
- 자동 Apply는 false 유지. ALB 활성화는 CI/CD 담당자와 협의 후 변경하고 최신 Plan에서 기존 공개 SG 규칙 외 의도하지 않은 삭제가 없는지 확인해야 합니다.
- ALB 80/443 전체 공개는 EX 예외 대장 및 Trivy 검사 범위에 대해 보안 담당자 검토를 요청합니다. 로컬 Apply 내역은 팀 사후 공유가 필요합니다.

### 후속 검토 및 검증

- 보안 담당: ALB 공개 범위 제한, 교육용 모의 은행 명시, 데모 자격증명 및 실제 개인정보 미사용 확인. 인증/DB 검증 전 외부 노출 최소화 권장.
- CI/CD 담당: Actions 변수 일치, CI Plan 재검증, 자동 Apply 비활성화 및 production 승인 절차 확인.
- 온프렘 담당: Core API → MariaDB 연동, 데모 로그인/조회/이체, AWS → DB 직접 접근 차단 실측.
- 운영: Target Group 장애 전환, OpenStack A/B Failover/Failback, ALB와 공인 IPv4 비용 및 종료 방식 검토. EC2 중지로 ALB 비용이 중단되지는 않습니다.

이번 PR은 11/27 보안 리뷰에 따라 Workflow, ALB 접근 제어, Lambda 예외 및 문서를 수정합니다. 실제 Actions 설정 변경과 AWS Apply는 팀 승인 이후 진행합니다.

## 9. 11/27 보안 검토 반영 (PR #30)

### EX-01 보안 예외

| 항목 | 내용 |
|---|---|
| 기준 | NET-02, LOG-06 |
| 대상 | Internet-facing ALB 및 ALB Security Group TCP 80/443 |
| 공개 범위 | 시연 기간 0.0.0.0/0 |
| 80번 목적 | HTTPS 리다이렉트 |
| 443번 목적 | 외부 고객 웹 서비스 |
| 검증 기간 | 승인된 팀원 IPv4 /32만 허용 |
| Trivy 예외 | AVD-AWS-0107, AVD-AWS-0053 (리소스 단위) |
| Lambda 예외 | 전체 공개 모드에서만 ALB SG의 TCP 80/443 허용 |
| 만료 및 재검토 | 2026-12-04 |
| 승인 | 11/27 송윤지 PR 승인, 문서 수정 및 공개 전환 조건 준수 전제 |

### 보안 개선

- Trivy 기본, ALB 공개, ALB 제한 모드 검사
- EX-01 및 만료일 주석 추가
- ALB 공개 모드에 따른 Lambda 자동 차단 예외 연동
- 검증 기간 팀 IP 제한
- 시연 후 제한 모드 복구 및 예외 재검토
- ACM ARN 및 팀원 IP 목록은 Actions Secret으로 관리
- Terraform 및 Drift Workflow의 변수 전달 일치
- Worker NodePort 30080은 ALB SG에서만 접근 허용
- 자동 Apply 비활성화 유지
- Lambda 예외 적용 및 SG 공개 전환 순서 검증 필요

### 최신 검증 결과

- AWS A/C에서 온프렘 A/B Core API 경유 DB 조회 4/4 성공
- MariaDB TCP 3306 직접 연결 실패 4/4 확인
- DB 접근 실패 원인별 보안 정책 검증은 추가 필요
- Argo CD A/C Synced
- 홈페이지 로그인 HTTP 500 및 Core API Timeout 조사 중
- 이체 및 DB 복제와 자동 장애 전환 미검증

본 변경은 코드 작성 및 검토 단계이며 실제 AWS Apply는 수행하지 않았다.

### 11/27 추가 CI 보안 검토

- Security Scan #72: ALB 활성화 검사에서 AWS-0053(HIGH) 탐지.
- Internet-facing ALB 리소스에 AVD-AWS-0053 예외 주석 추가.
- EX-01 예외 대장 개정안 작성, 11/27 보안 담당 PR 승인(조건부 공개 전환).
- Security Scan #73: Gitleaks, TFLint, Trivy 기본/공개/제한 모드 모두 통과.
- 팀원 6명 제한 모드 Plan: 12 add / 0 change / 2 destroy.
- 삭제 대상은 기존 공개 TCP 80/443 SG 규칙으로 한정.
- Actions 변수 설정 반영 기록 및 최신 CI Plan(4aa3088): `12 to add, 2 to change, 2 to destroy`. 기존 공개 SG 규칙 2개 제거 및 팀원 /32 규칙 12개 추가, 서울 및 us-east-1 Lambda in-place 변경 예정. 실제 현재 변수값 및 상세 diff는 Apply 직전 재확인 필요.
- 실제 AWS Apply 미진행.

### 공개 전환 및 제한 모드 복구 절차 (EX-01)

적용 전제: 로그인 HTTP 500 및 Core API Timeout 해결, 실제 로그인 성공 및 AWS → MariaDB TCP 3306 차단 원인(허용/차단 정책과 실측의 일치) 검증 전에는 공개 모드로 전환하지 않습니다. AWS 인프라 담당자가 보안 담당자 및 CI/CD 담당자와 협의하여 승인된 팀원 /32 목록을 Repository Secret에 유지하고, `TF_VAR_AWS_ALB_PUBLIC_ACCESS=false`, `TF_APPLY_ENABLED=false`, `auto_revoke_mode=notify`를 기본으로 유지합니다. 공개 승인 후에만 관리자가 `TF_VAR_AWS_ALB_PUBLIC_ACCESS=true`로 변경하고 최신 Terraform Plan에서 ALB SG TCP 80/443 및 서울 Lambda의 ALB 예외 반영 범위, Lambda/SG 적용 순서, 의도하지 않은 삭제·교체가 없는지 검토한 뒤 팀 승인된 수동 Apply를 수행합니다. 시연 종료 후 동일 담당자가 `TF_VAR_AWS_ALB_PUBLIC_ACCESS=false`로 복구하고 Plan/승인/Apply 및 팀원 접근·비승인 IP 차단·Lambda 예외 제거를 재검증합니다. 자동 Apply는 비활성화 유지하며 2026-12-04에 EX-01 예외를 재검토합니다.

### sec_responder_use1 변경 사유 및 확인 범위

서울 `sec_responder`와 us-east-1 `sec_responder_use1`은 동일한 `data.archive_file.sec_responder` ZIP 및 `source_code_hash`를 참조합니다. 최신 CI Plan에는 두 함수의 in-place 변경이 표시되지만 요약에는 세부 속성이 없어 us-east-1 변경의 직접 원인(공유 패키지 해시 차이 등)은 상세 Plan으로 확인해야 합니다. us-east-1은 IAM/root 등 글로벌 이벤트 알림용이며 `MODE=notify`, `EXCEPTIONS={}` 고정으로 유지됩니다. ALB 공개 예외 환경변수 변경은 서울 함수에만 적용하며 글로벌 Lambda의 차단 권한/정책 확대나 리소스 교체를 의도하지 않습니다. 상세 Plan에 예상 외 환경변수, IAM, 교체 또는 삭제 변경이 있으면 Apply를 중단합니다.
