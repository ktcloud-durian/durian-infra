variable "aws_web_assets_enabled" {
  description = "Create private S3 bucket for non-sensitive web assets"
  type        = bool
  default     = false
}

locals {
  durian_bucket_purposes = setunion(
    var.buckets,
    var.aws_web_assets_enabled ? toset(["web-assets"]) : toset([])
  )
}

# Temporary web files: expire after 7 days
resource "aws_s3_bucket_lifecycle_configuration" "web_assets_temp" {
  count  = var.aws_web_assets_enabled ? 1 : 0
  bucket = aws_s3_bucket.this["web-assets"].id

  rule {
    id     = "expire-temp-files"
    status = "Enabled"

    filter {
      prefix = "temp/"
    }

    expiration {
      days = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

output "aws_web_assets_bucket" {
  description = "Private bucket for non-sensitive DURIAN web data"
  value       = var.aws_web_assets_enabled ? aws_s3_bucket.this["web-assets"].bucket : null
}
