# durian terraform

```
bootstrap/        1회만 실행. state용 S3 버킷 + GitHub OIDC Role (로컬 state 사용)
modules/network   VPC, public subnet
modules/k3s-node  Ubuntu 24.04 EC2 + k3s (SSM 접속, SSH 포트 없음)
envs/dev          개발 환경 (state는 S3)
```

## 사전 준비 (본인 PC)

1. AWS 루트 계정: MFA 켜기, Budgets 알림 설정 (월 $20, $50)
2. 관리용 사용자: IAM Identity Center(SSO) 권장. 장기 액세스 키는 만들지 않음
3. 도구 설치: `winget install -e --id Hashicorp.Terraform`, `winget install -e --id Amazon.AWSCLI`
4. 로그인: `aws configure sso` (프로필 이름 예: `durian`), 이후 `aws sso login --profile durian`
5. PowerShell에서 `$env:AWS_PROFILE = "durian"`

## 1단계: bootstrap

```powershell
cd C:\durian-platform\terraform\bootstrap
terraform init
terraform plan
terraform apply
terraform output
```

- 출력된 `state_bucket`, `gha_plan_role_arn`을 메모
- bootstrap의 state 파일(`terraform.tfstate`)은 로컬에 남고 git에 올리지 않음 (.gitignore 처리됨)

## 2단계: dev 환경

```powershell
cd C:\durian-platform\terraform\envs\dev
copy backend.hcl.example backend.hcl        # bucket 이름 입력
copy terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

- 접속: `aws ssm start-session --target <k3s_instance_id>` (session-manager-plugin 필요)
- kubeconfig: 인스턴스 안의 `/etc/rancher/k3s/k3s.yaml`

## 비용 주의

- t3.large 상시 가동 시 월 약 $76 + EBS/IP. 사용하지 않을 때는 `terraform destroy` 또는 인스턴스 중지
- Budgets 알림을 먼저 설정할 것

## 규칙

- `terraform apply`는 로컬에서 사람이 실행. CI는 `plan`(읽기 전용 Role)까지만
- `*.tfstate`, `*.tfvars`, `backend.hcl`은 git에 올리지 않음

## GitHub Actions (durian-infra)

- PR: `terraform plan`(읽기 전용 Role)을 실행하고 결과를 PR 코멘트로 남김
- main 병합: `production` Environment 승인 후 `apply` (**기본 비활성**, 변수 `TF_APPLY_ENABLED=true`일 때만 실행)
- 필요한 Repository variables: `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_APPLY_ENABLED`
- 필요한 Environment: `production`
- `bootstrap/`은 로컬에서만 실행 (Actions 대상 아님). `bootstrap/terraform.tfstate`는 Git에 올리지 않으므로 백업해 둘 것

## 정리(teardown) 순서 — 다른 계정으로 옮기기 전

순서를 지켜야 합니다. state 버킷을 먼저 지우면 dev를 지울 수 없습니다.

1. dev 환경 삭제 (Actions의 Terraform > Run workflow > confirm에 `destroy`, 또는 로컬)
   ```powershell
   cd envs\dev
   terraform destroy
   ```
2. bootstrap 삭제 (S3 state 버킷, OIDC 제공자, Role 2개)
   ```powershell
   cd ..\..\bootstrap
   terraform apply -var="force_destroy_state=true"
   terraform destroy -var="force_destroy_state=true"
   ```
3. 본인 계정의 `durian` IAM 사용자/액세스 키 삭제, PC의 프로필 정리 (`aws configure` 파일의 `[durian]`)
4. GitHub `durian-infra`의 Variables(`AWS_*`, `TF_*`)와 Environment 삭제
5. 새 계정에서는 `github_owner`, `github_owner_id`, 저장소 이름을 맞춰 bootstrap부터 다시 실행

<!-- plan test -->
