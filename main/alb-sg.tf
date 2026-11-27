# ALB -> each independent K3s Worker. Never expose NodePort to public CIDRs.
# ALB is disabled by default; same target group may include Worker A and Worker C.
resource "aws_vpc_security_group_ingress_rule" "web_worker_from_alb" {
  for_each                     = var.aws_alb_enabled ? local.az_keys : {}
  security_group_id            = aws_security_group.k3s_worker[each.key].id
  referenced_security_group_id = aws_security_group.role["alb"].id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  description                  = "ALB to Cluster ${each.key} Traefik HTTP NodePort"
}

resource "aws_vpc_security_group_egress_rule" "web_alb_to_worker" {
  for_each                     = var.aws_alb_enabled ? local.az_keys : {}
  security_group_id            = aws_security_group.role["alb"].id
  referenced_security_group_id = aws_security_group.k3s_worker[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  description                  = "ALB to Cluster ${each.key} K3s Worker NodePort"
}

# EX-01: Public HTTP for HTTPS redirect only
#trivy:ignore:AVD-AWS-0107:exp:2026-12-04
resource "aws_vpc_security_group_ingress_rule" "web_alb_http_redirect" {
  depends_on        = [aws_lambda_function.sec_responder]
  count             = var.aws_alb_enabled && var.aws_alb_public_access ? 1 : 0
  security_group_id = aws_security_group.role["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Public HTTP for HTTPS redirect only"
}
