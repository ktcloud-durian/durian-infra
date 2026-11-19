# DURIAN K3s HA - Master peer API communication
# Only instances in the Master SG can use TCP 6443.

resource "aws_vpc_security_group_ingress_rule" "k3s_master_peer_api" {
  security_group_id            = aws_security_group.role["master"].id
  referenced_security_group_id = aws_security_group.role["master"].id

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443

  description = "K3s Master to Master API"
}

resource "aws_vpc_security_group_egress_rule" "k3s_master_peer_api" {
  security_group_id            = aws_security_group.role["master"].id
  referenced_security_group_id = aws_security_group.role["master"].id

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443

  description = "K3s Master peer API outbound"
}
