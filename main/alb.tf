variable "aws_alb_enabled" {
  description = "Deploy the public K3s web ALB only after explicit approval"
  type        = bool
  default     = false
}

variable "aws_alb_certificate_arn" {
  description = "Approved ACM certificate ARN in the same region as ALB"
  type        = string
  default     = ""
}

resource "terraform_data" "web_alb_guard" {
  count = var.aws_alb_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = var.aws_k3s_enabled && var.aws_k3s_bootstrap_approved && startswith(var.aws_alb_certificate_arn, "arn:aws:acm:${var.region}:")
      error_message = "ALB requires approved K3s deployment and a valid in-region ACM certificate ARN."
    }
    precondition {
      condition     = var.aws_alb_public_access || length(var.aws_alb_allowed_cidrs) > 0
      error_message = "Restricted ALB access requires at least one approved team IPv4 address."
    }
  }
}

# EX-01: Internet-facing ALB for external HTTPS service (review pending)
#trivy:ignore:AVD-AWS-0053:exp:2026-12-04
resource "aws_lb" "web" {
  count                      = var.aws_alb_enabled ? 1 : 0
  depends_on                 = [terraform_data.web_alb_guard]
  name                       = substr("${var.name}-web-alb", 0, 32)
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.role["alb"].id]
  subnets                    = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]
  enable_deletion_protection = false
  drop_invalid_header_fields = true
  tags                       = { Name = "${var.name}-web-alb" }
}

resource "aws_lb_target_group" "web" {
  count                = var.aws_alb_enabled ? 1 : 0
  name                 = substr("${var.name}-k3s-web-tg", 0, 32)
  port                 = 30080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.this.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${var.name}-k3s-web-tg" }
}

resource "aws_lb_listener" "web_https" {
  count             = var.aws_alb_enabled ? 1 : 0
  load_balancer_arn = aws_lb.web[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.aws_alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web[0].arn
  }
}

output "aws_web_alb_dns" {
  description = "Created only after aws_alb_enabled is approved"
  value       = var.aws_alb_enabled ? aws_lb.web[0].dns_name : null
}

resource "aws_lb_listener" "web_http_redirect" {
  count             = var.aws_alb_enabled ? 1 : 0
  load_balancer_arn = aws_lb.web[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
