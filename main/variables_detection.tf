# 탐지·자동 대응 변수 (detection.tf) — 담당: 보안

variable "auto_revoke_mode" {
  description = "notify = 공개 규칙을 찾으면 알림만 / revoke = 실제로 삭제. ALB 80/443 예외 검증 및 보안 승인 전에는 notify로 둠"
  type        = string
  default     = "notify"
  validation {
    condition     = contains(["notify", "revoke"], var.auto_revoke_mode)
    error_message = "auto_revoke_mode 는 notify 또는 revoke"
  }
}

variable "public_ingress_exceptions" {
  description = "승인된 공개 보안그룹과 포트. ALB EX-01은 공개 모드에 따라 detection.tf에서 별도로 관리. 예: { \"sg-0abc...\" = [443] }"
  type        = map(list(number))
  default     = {}
}

variable "security_webhook_param" {
  description = "Discord 보안 채널 웹훅 URL을 넣어 둔 SSM SecureString 이름 (값은 콘솔에서 직접 넣고 코드·state에 두지 않음)"
  type        = string
  default     = "/durian/security/discord-webhook"
}
