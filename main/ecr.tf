# DURIAN application ECR repository
resource "aws_ecr_repository" "app" {
  name                 = "durian-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "durian-app"
  }
}

# K3s Worker EC2: ECR 이미지 다운로드 권한
resource "aws_iam_role_policy" "worker_ecr_pull" {
  name = "durian-worker-ecr-pull"
  role = aws_iam_role.k3s["worker"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = aws_ecr_repository.app.arn
      }
    ]
  })
}

output "ecr_app_url" {
  value = aws_ecr_repository.app.repository_url
}

# Untagged images only: expire after 30 days
# Tagged release images are preserved for rollback.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 30 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
