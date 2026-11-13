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
