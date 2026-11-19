# 보안 설정용 변수 (security.tf, cloudtrail.tf) — 담당: 보안

variable "default_sg_extra_vpc_ids" {
  description = "Terraform 밖 VPC 중 default 보안그룹 규칙을 비울 VPC ID 목록 (계정 기본 VPC 등)"
  type        = list(string)
  default     = []
}

variable "trail_log_retention_days" {
  description = "CloudTrail 로그를 S3에 남기는 기간(일)"
  type        = number
  default     = 90
}

variable "enable_guardduty" {
  description = "GuardDuty 켜기 (LOG-05). 30일 무료라 켜는 날을 정한 뒤 true"
  type        = bool
  default     = false
}
