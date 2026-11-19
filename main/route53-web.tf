variable "aws_web_domain_name" {
  description = "Approved public web domain, e.g. bank.example.com"
  type        = string
  default     = ""
}

variable "aws_web_route53_zone_id" {
  description = "Existing public Route53 hosted zone ID"
  type        = string
  default     = ""
}

resource "aws_route53_record" "web_alias" {
  count = (
    var.aws_alb_enabled &&
    var.aws_web_domain_name != "" &&
    var.aws_web_route53_zone_id != ""
  ) ? 1 : 0

  zone_id = var.aws_web_route53_zone_id
  name    = var.aws_web_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.web[0].dns_name
    zone_id                = aws_lb.web[0].zone_id
    evaluate_target_health = true
  }
}
