# DURIAN - Initial Security Group Egress Rules
# Review with SecurityOps before terraform apply.

locals {
  bootstrap_roles = toset(["master", "worker", "mgmt"])
}

# HTTPS: SSM, ECR, GitHub, package downloads
resource "aws_vpc_security_group_egress_rule" "bootstrap_https" {
  for_each = local.bootstrap_roles

  security_group_id = aws_security_group.role[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  description = "Bootstrap HTTPS outbound"
}

# HTTP: Ubuntu package repositories during initial setup
resource "aws_vpc_security_group_egress_rule" "bootstrap_http" {
  for_each = local.bootstrap_roles

  security_group_id = aws_security_group.role[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80

  description = "Ubuntu package repository HTTP"
}

# Worker -> Master Kubernetes API
resource "aws_vpc_security_group_egress_rule" "worker_master_api" {
  security_group_id            = aws_security_group.role["worker"].id
  referenced_security_group_id = aws_security_group.role["master"].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443

  description = "Worker to K3s master API"
}

# K3s common SG: Flannel VXLAN
resource "aws_vpc_security_group_egress_rule" "node_flannel" {
  security_group_id            = aws_security_group.role["node"].id
  referenced_security_group_id = aws_security_group.role["node"].id
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472

  description = "K3s node VXLAN"
}

# K3s common SG: kubelet
resource "aws_vpc_security_group_egress_rule" "node_kubelet" {
  security_group_id            = aws_security_group.role["node"].id
  referenced_security_group_id = aws_security_group.role["node"].id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250

  description = "K3s node kubelet communication"
}

# Monitor -> K3s Node Exporter
resource "aws_vpc_security_group_egress_rule" "mgmt_node_exporter" {
  security_group_id            = aws_security_group.role["mgmt"].id
  referenced_security_group_id = aws_security_group.role["node"].id
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100

  description = "Monitor to K3s Node Exporter"
}
