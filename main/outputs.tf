output "instances" {
  value = {
    for k, i in aws_instance.this : k => {
      id         = i.id
      public_ip  = i.public_ip
      private_ip = i.private_ip
    }
  }
}

output "buckets" {
  value = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnets" {
  value = {
    public      = { for k, v in aws_subnet.public : k => v.id }
    private_app = { for k, v in aws_subnet.private_app : k => v.id }
    private_mon = { for k, v in aws_subnet.private_mon : k => v.id }
  }
}
