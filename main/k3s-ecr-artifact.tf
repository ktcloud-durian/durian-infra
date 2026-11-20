variable "aws_k3s_ecr_s3_bucket" {
  description = "Approved private S3 artifact bucket"
  type        = string
  default     = ""
}

variable "aws_k3s_ecr_s3_key" {
  description = "ECR provider artifact object key"
  type        = string
  default     = "artifacts/k3s/ecr-provider/v1.34.3/linux-amd64/ecr-credential-provider"
}

resource "aws_iam_role_policy" "k3s_ecr_artifact_read" {
  for_each = var.aws_k3s_image_registry == "ecr" && var.aws_k3s_enabled && var.aws_k3s_ecr_s3_bucket != "" ? local.k3s_roles : toset([])

  name = "durian-k3s-ecr-artifact-read"
  role = aws_iam_role.k3s[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "arn:aws:s3:::${var.aws_k3s_ecr_s3_bucket}/${var.aws_k3s_ecr_s3_key}"
    }]
  })
}
