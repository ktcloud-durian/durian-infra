# 보안 기본 설정 (보안 기준서 v1.1) — 11/18 첫 AWS 점검에서 나온 위반(EBS 암호화 꺼짐, CloudTrail 없음, default SG 규칙)을 코드로 고정
# 담당: 보안(송윤지). 콘솔에서 직접 바꾸지 않고 이 파일을 PR로 고침 (NET-05)

data "aws_partition" "current" {}

# SRV-02, CIS EC2.7 — 이 리전에서 새로 만드는 EBS 볼륨을 항상 암호화 (이미 있는 볼륨은 그대로)
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# SRV-01, CIS EC2.8 — 새 EC2의 기본 메타데이터 설정을 IMDSv2만 허용 (ec2.tf도 이미 required)
resource "aws_ec2_instance_metadata_defaults" "this" {
  http_tokens                 = "required"
  http_put_response_hop_limit = 2 # k3s 파드에서 IMDS에 닿으려면 2 필요
}

# DAT-02, CIS S3.1 — 계정 전체 S3 퍼블릭 액세스 차단 (s3.tf의 버킷별 차단과 별개로 계정 단위)
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM-03, CIS IAM.15 — 비밀번호 정책
# 주의: 계정에 하나뿐인 설정이라 apply하면 콘솔 값을 덮어씀. PR의 plan 댓글에서 바뀌는 값이 없는지 먼저 확인
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

# NET-03, CIS EC2.2 — default 보안그룹의 규칙을 모두 비움 (지우지 않고 가져와서 규칙 0개로 덮어씀)
resource "aws_default_security_group" "durian" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-sg-unused" }
}

# 계정 기본 VPC 등 Terraform 밖의 VPC (11/18 점검에서 default SG 규칙이 남은 VPC). ID는 terraform.tfvars에
resource "aws_default_security_group" "extra" {
  for_each = toset(var.default_sg_extra_vpc_ids)
  vpc_id   = each.value
  tags     = { Name = "${var.name}-default-sg-unused" }
}

# LOG-05 — GuardDuty. 30일 무료 체험이라 켜는 날을 정한 뒤 enable_guardduty = true
resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}
