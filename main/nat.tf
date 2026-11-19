# DURIAN NAT EC2 - one instance per AZ
# Existing VPC and subnet CIDRs are preserved.

variable "nat_ami_id" {
  type    = string
  default = "ami-0e0eaae1fc96ade32"
}

variable "nat_instance_type" {
  type    = string
  default = "t3.micro"
}

resource "aws_instance" "nat" {
  for_each = local.az_keys

  ami                         = var.nat_ami_id
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

# NAT receives forwarding traffic from private app subnets.
resource "aws_vpc_security_group_ingress_rule" "nat_app" {
  for_each = local.az_keys

  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = aws_subnet.private_app[each.key].cidr_block
  ip_protocol       = "-1"

  description = "Forward traffic from private app"
}

# NAT receives forwarding traffic from private monitor subnets.
resource "aws_vpc_security_group_ingress_rule" "nat_mon" {
  for_each = local.az_keys

  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = aws_subnet.private_mon[each.key].cidr_block
  ip_protocol       = "-1"

  description = "Forward traffic from private monitor"
}

# NAT must forward traffic to internet destinations.
# Security review required before deployment.
resource "aws_vpc_security_group_egress_rule" "nat_internet" {
  security_group_id = aws_security_group.role["nat"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  description = "NAT internet forwarding"
}

# Existing private route tables point to NAT ENIs.
resource "aws_route" "private_nat" {
  for_each = local.az_keys

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[each.key].primary_network_interface_id

  depends_on = [aws_route.public_igw]
}
