# 지금은 기본 VPC 사용. 나중에 새 VPC/프라이빗 서브넷/NAT로 전환할 때 이 파일만 교체한다.
data "aws_vpc" "this" {
  default = true
}

data "aws_subnets" "this" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  vpc_id    = data.aws_vpc.this.id
  subnet_id = coalesce(var.subnet_id, sort(data.aws_subnets.this.ids)[0])
}
