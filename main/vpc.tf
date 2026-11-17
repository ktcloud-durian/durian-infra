# durian VPC (Multi-AZ). 서브넷 구성: AZ별 public / private-app(K3s) / private-mon(Monitor)
# NAT 인스턴스와 프라이빗 라우트(0.0.0.0/0)는 nat.tf 추가 시 연결한다.
locals {
  az_keys = { for i, az in var.azs : substr(az, -1, 1) => { az = az, idx = i } }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  for_each                = local.az_keys
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.az
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value.idx)
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "private_app" {
  for_each          = local.az_keys
  vpc_id            = aws_vpc.this.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + each.value.idx)
  tags              = { Name = "${var.name}-private-app-${each.key}", Tier = "private-app" }
}

resource "aws_subnet" "private_mon" {
  for_each          = local.az_keys
  vpc_id            = aws_vpc.this.id
  availability_zone = each.value.az
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + each.value.idx)
  tags              = { Name = "${var.name}-private-mon-${each.key}", Tier = "private-mon" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public-rt" }
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = local.az_keys
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# AZ별 프라이빗 라우트 테이블 (NAT 인스턴스를 AZ별로 붙이기 위함)
resource "aws_route_table" "private" {
  for_each = local.az_keys
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "${var.name}-private-rt-${each.key}" }
}

resource "aws_route_table_association" "private_app" {
  for_each       = local.az_keys
  subnet_id      = aws_subnet.private_app[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_mon" {
  for_each       = local.az_keys
  subnet_id      = aws_subnet.private_mon[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

locals {
  vpc_id    = aws_vpc.this.id
  subnet_id = coalesce(var.subnet_id, aws_subnet.public[sort(keys(local.az_keys))[0]].id)
}
