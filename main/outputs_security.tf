output "cloudtrail_arn" {
  value = aws_cloudtrail.this.arn
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.trail.id
}

output "guardduty_detector_id" {
  value = try(aws_guardduty_detector.this[0].id, null)
}
