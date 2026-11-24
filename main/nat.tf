# DURIAN NAT EC2 - one instance per AZ
# Existing VPC and subnet CIDRs are preserved.

variable "nat_enabled" {
  description = "Enable NAT EC2 after team approval"
  type        = bool
  default     = false
}

variable "nat_ami_id" {
  type    = string
  default = null
}

variable "nat_instance_type" {
  type    = string
  default = "t3.micro"
}

resource "aws_instance" "nat" {
  for_each = var.nat_enabled ? local.az_keys : {}

  ami                         = coalesce(var.nat_ami_id, data.aws_ssm_parameter.ubuntu.value)
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[each.key].id
  associate_public_ip_address = true

  source_dest_check = false

  vpc_security_group_ids = [
    aws_security_group.role["nat"].id
  ]

  iam_instance_profile = aws_iam_instance_profile.node.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/scripts/nat.sh.tftpl", {
    app_cidr = aws_subnet.private_app[each.key].cidr_block
    mon_cidr = aws_subnet.private_mon[each.key].cidr_block
  })

  user_data_replace_on_change = true

  tags = {
    Name = "durian-nat-${each.key}"
    Role = "nat"
  }
}

# NAT traffic restricted to approved service ports.
locals {
  nat_allowed_ports = {
    http             = { protocol = "tcp", port = 80 }
    https            = { protocol = "tcp", port = 443 }
    tailscale_direct = { protocol = "udp", port = 41641 }
    tailscale_stun   = { protocol = "udp", port = 3478 }
  }

  nat_allowed_ingress = var.nat_enabled ? {
    for item in setproduct(keys(local.az_keys), keys(local.nat_allowed_ports)) :
    "${item[0]}-${item[1]}" => {
      az       = item[0]
      protocol = local.nat_allowed_ports[item[1]].protocol
      port     = local.nat_allowed_ports[item[1]].port
    }
  } : {}
}

resource "aws_vpc_security_group_ingress_rule" "nat_app" {
  for_each = local.nat_allowed_ingress

  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = aws_subnet.private_app[each.value.az].cidr_block
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port

  description = "Private app ${each.value.protocol} ${each.value.port} to NAT"
}

resource "aws_vpc_security_group_ingress_rule" "nat_mon" {
  for_each = local.nat_allowed_ingress

  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = aws_subnet.private_mon[each.value.az].cidr_block
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port

  description = "Private monitor ${each.value.protocol} ${each.value.port} to NAT"
}

# EX-03 (NET-01): approved NAT instance egress 80/443/tcp and 3478/41641/udp
# Scope: this Terraform resource only. Review 2026-12-04.
#trivy:ignore:AVD-AWS-0104:exp:2026-12-04
resource "aws_vpc_security_group_egress_rule" "nat_internet" {
  for_each = var.nat_enabled ? local.nat_allowed_ports : {}

  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port

  description = "NAT outbound ${each.value.protocol} ${each.value.port}"
}

# Existing private route tables point to NAT ENIs.
resource "aws_route" "private_nat" {
  for_each = var.nat_enabled ? local.az_keys : {}

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[each.key].primary_network_interface_id

  depends_on = [aws_route.public_igw]
}
