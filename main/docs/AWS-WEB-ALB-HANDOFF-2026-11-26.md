# AWS 웹 서비스 구축 및 ALB·Route 53 배포 검토 (2026-11-26)

> 배포 준비 및 승인 요청용 기록입니다. 팀 승인 전 Merge 및 Apply를 진행하지 않습니다. 이 문서 추가 자체는 인프라 구성을 변경하지 않습니다.

## 1. 구축 및 검증 내역 (11/25~11/26)

- 기존 AWS A/C 독립 K3s 클러스터 및 Argo CD 기반 Bank Web 배포 구성 사용.
- Traefik HTTP NodePort 30080을 통한 SSM 포트 포워딩 웹 접속: A/C 성공.
- AWS A/C Web Pod에서 OpenStack A Core API의 `/health` HTTP 200 및 인증 없는 내부 API 요청 HTTP 401 확인.
- AWS Worker A/C 호스트에서 OpenStack A API Health Check 200 확인.
- OpenStack B API 연결은 별도 작업: A/C 클러스터의 임시 Web Egress 정책 추가 후에도 VPN 경로 미수신 확인. GitOps 영구 반영 및 B API 재검증은 미완료.
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
- [x] 도메인, Route 53 위임 및 ACM 발급
- [x] 로컬 ALB Terraform Plan
- [ ] Actions 변수 전달 및 접근 정책 코드 정리
- [ ] 최신 main 기준 CI Plan 및 보안 검사
- [ ] 팀 리뷰 및 배포 승인
- [ ] 승인된 방식으로 Terraform Apply (다른 팀원 배포와 중복 금지)
- [ ] ALB Target Group A/C Healthy 확인
- [ ] Route 53 Alias 및 HTTPS 접속, HTTP 리다이렉트 확인
- [ ] 로그인/금융 기능 별도 검증
- [ ] OpenStack B 연결 및 GitOps 정책 별도 검증

## 6. 비용 및 운영

ALB는 Worker/EC2 중지와 별개로 사용 요금이 발생할 수 있으므로 시연 외 운영 여부 및 제거 계획을 팀과 협의. 정리 시 전체 terraform destroy 대신 ALB 관련 변경 범위를 검토한 Plan으로 진행하고, DNS 검증 CNAME과 Hosted Zone, ACM 인증서는 후속 사용 여부에 맞춰 유지.

## 7. 리뷰 요청

- ALB 80/443 최초 접근 범위 및 공개 기준
- ASG 및 Launch Template, Monitor IAM 변경 영향
- GitHub Actions 변수 전달 및 배포 승인 절차
- ALB 생성 및 운영 비용 승인

현 시점 ALB Apply, Target Group Healthy 및 HTTPS 외부 접속은 미검증입니다.
