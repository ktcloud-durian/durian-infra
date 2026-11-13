# S3 버킷은 개수가 정해지지 않아 기본값은 "없음".
# 필요해지면 terraform.tfvars의 buckets에 용도 이름만 추가한다. (예: ["upload", "backup"])
# 이름 규칙: durian-<용도>-<계정ID>  (전 세계 유일)
data "aws_caller_identity" "me" {}

resource "aws_s3_bucket" "this" {
  for_each = var.buckets
  bucket   = "durian-${each.key}-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}
