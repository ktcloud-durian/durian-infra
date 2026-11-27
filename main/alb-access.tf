variable "aws_alb_public_access" {
  description = "Allow public ALB access only during approved demo periods"
  type        = bool
  default     = false
}

variable "aws_alb_allowed_cidrs" {
  description = "Approved team public IPv4 addresses during verification"
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.aws_alb_allowed_cidrs :
      can(cidrnetmask(cidr)) && endswith(cidr, "/32")
    ])
    error_message = "Only individual IPv4 /32 addresses are allowed."
  }
}

moved {
  from = aws_vpc_security_group_ingress_rule.alb_https
  to   = aws_vpc_security_group_ingress_rule.alb_https[0]
}

resource "aws_vpc_security_group_ingress_rule" "alb_team_http" {
  for_each = var.aws_alb_enabled && !var.aws_alb_public_access ? var.aws_alb_allowed_cidrs : toset([])

  security_group_id = aws_security_group.role["alb"].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Team HTTP to HTTPS redirect"
}

resource "aws_vpc_security_group_ingress_rule" "alb_team_https" {
  for_each = var.aws_alb_enabled && !var.aws_alb_public_access ? var.aws_alb_allowed_cidrs : toset([])

  security_group_id = aws_security_group.role["alb"].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Team HTTPS verification access"
}
