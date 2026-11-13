# 인바운드는 기본적으로 없음 (접속은 SSM / Tailscale). 필요한 것만 추가한다.
resource "aws_security_group" "node" {
  name        = "durian-node"
  description = "durian EC2 nodes"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "k8s_api" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "Kubernetes API from admin"
}
