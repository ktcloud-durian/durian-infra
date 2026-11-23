# DURIAN v0.3 - Role-based Security Groups
# Existing durian-node SG remains unchanged.

locals {
  sg_roles = toset([
    "alb",
    "master",
    "worker",
    "node",
    "mgmt",
    "nat"
  ])
}

resource "aws_security_group" "role" {
  for_each = local.sg_roles

  name        = "durian-${each.key}-sg"
  description = "DURIAN ${each.key} security group"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "durian-${each.key}-sg"
    Role = each.key
  }
}

# External HTTPS to ALB
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.role["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Public HTTPS access to ALB"
}

# Worker to K3s Master API
resource "aws_vpc_security_group_ingress_rule" "master_api" {
  security_group_id            = aws_security_group.role["master"].id
  referenced_security_group_id = aws_security_group.role["worker"].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Worker to K3s Master API"
}

# K3s Flannel VXLAN between nodes
resource "aws_vpc_security_group_ingress_rule" "node_flannel" {
  security_group_id            = aws_security_group.role["node"].id
  referenced_security_group_id = aws_security_group.role["node"].id
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  description                  = "K3s Flannel VXLAN between nodes"
}

# Kubelet communication between nodes
resource "aws_vpc_security_group_ingress_rule" "node_kubelet" {
  security_group_id            = aws_security_group.role["node"].id
  referenced_security_group_id = aws_security_group.role["node"].id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "K3s Kubelet between nodes"
}

# Prometheus Node Exporter access from Monitor
resource "aws_vpc_security_group_ingress_rule" "node_exporter" {
  security_group_id            = aws_security_group.role["node"].id
  referenced_security_group_id = aws_security_group.role["mgmt"].id
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
  description                  = "Monitoring to K3s Node Exporter"
}
