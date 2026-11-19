# No direct public access to K3s Workers; the ALB can reach only TCP 30080.
resource "aws_vpc_security_group_ingress_rule" "web_worker_from_alb" {
  count                        = var.aws_alb_enabled ? 1 : 0
  security_group_id            = aws_security_group.role["worker"].id
  referenced_security_group_id = aws_security_group.role["alb"].id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  description                  = "ALB to Traefik HTTP NodePort only"
}

resource "aws_vpc_security_group_egress_rule" "web_alb_to_worker" {
  count                        = var.aws_alb_enabled ? 1 : 0
  security_group_id            = aws_security_group.role["alb"].id
  referenced_security_group_id = aws_security_group.role["worker"].id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  description                  = "ALB to K3s worker only"
}
