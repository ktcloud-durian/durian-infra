# DURIAN Monitor-only AZ 2b private subnet with existing NAT A reuse.
# Keep var.azs unchanged: K3s and NAT remain A/C only.
# Requires monitor_enabled=true and nat_enabled=true.

resource "aws_subnet" "monitor_b" {
  count             = var.monitor_enabled ? 1 : 0
  vpc_id            = aws_vpc.this.id
  availability_zone = "${var.region}b"
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 22)

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-private-mon-b"
    Tier = "private-mon"
    Role = "monitor"
  }
}

resource "aws_route_table" "monitor_b" {
  count  = var.monitor_enabled ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-rt-mon-b" }
}

resource "aws_route_table_association" "monitor_b" {
  count          = var.monitor_enabled ? 1 : 0
  subnet_id      = aws_subnet.monitor_b[0].id
  route_table_id = aws_route_table.monitor_b[0].id
}

# 2b Monitor egress uses NAT A's existing ENI in 2a. Do not create another NAT EC2.
resource "aws_route" "monitor_b_nat" {
  count                  = var.monitor_enabled && var.nat_enabled ? 1 : 0
  route_table_id         = aws_route_table.monitor_b[0].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat["a"].primary_network_interface_id
  depends_on             = [aws_route.public_igw]
}

# NAT security group accepts monitor 2b subnet on approved internet ports only.
# The same port set is already defined in nat.tf; no changes to other AZ rules.
resource "aws_vpc_security_group_ingress_rule" "nat_monitor_b" {
  for_each = var.monitor_enabled && var.nat_enabled ? local.nat_allowed_ports : {}

  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = aws_subnet.monitor_b[0].cidr_block
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Monitor 2b to existing NAT A ${each.value.protocol}/${each.value.port}"
}

# NAT A's original cloud-init restricts forwarding to subnet A CIDRs.
# Change only the RUNNING NAT A host firewall via SSM, not NAT user_data.
# No NAT instance replacement. iptables-persistent retains rules on reboot.
# Review with SecurityOps before applying because this modifies NAT A OS state.
resource "aws_ssm_association" "monitor_b_nat_rules" {
  count                            = var.monitor_enabled && var.nat_enabled ? 1 : 0
  name                             = "AWS-RunShellScript"
  association_name                 = "durian-nat-a-monitor-b-egress"
  wait_for_success_timeout_seconds = 600

  targets {
    key    = "InstanceIds"
    values = [aws_instance.nat["a"].id]
  }

  parameters = {
    commands = <<-SCRIPT
      #!/usr/bin/env bash
      set -euo pipefail
      NET='${aws_subnet.monitor_b[0].cidr_block}'
      test "$(sysctl -n net.ipv4.ip_forward)" = '1'
      WAN_IF=$(ip -o -4 route show default | awk '{print $5; exit}')
      test -n "$WAN_IF"
      command -v iptables >/dev/null
      command -v netfilter-persistent >/dev/null
      for PORT in 80 443; do
        iptables -C FORWARD -s "$NET" -o "$WAN_IF" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "$NET" -o "$WAN_IF" -p tcp --dport "$PORT" -j ACCEPT
      done
      for PORT in 3478 41641; do
        iptables -C FORWARD -s "$NET" -o "$WAN_IF" -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "$NET" -o "$WAN_IF" -p udp --dport "$PORT" -j ACCEPT
      done
      iptables -t nat -C POSTROUTING -s "$NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$NET" -o "$WAN_IF" -j MASQUERADE
      netfilter-persistent save
      echo "DURIAN Monitor subnet NAT-A rules installed for $NET"
    SCRIPT
  }

  depends_on = [
    aws_vpc_security_group_ingress_rule.nat_monitor_b,
    aws_route.monitor_b_nat
  ]
}