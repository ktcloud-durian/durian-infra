# DURIAN - K3s Master/Worker IAM roles
# 기존 durian-node IAM 역할은 변경하지 않음

locals {
  k3s_roles = toset(["master", "worker"])

  parameter_arn_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/durian"
}

# 역할별 EC2 IAM Role
resource "aws_iam_role" "k3s" {
  for_each = local.k3s_roles

  name               = "durian-k3s-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# EC2에 IAM Role 연결할 때 사용할 프로파일
resource "aws_iam_instance_profile" "k3s" {
  for_each = local.k3s_roles

  name = "durian-k3s-${each.key}"
  role = aws_iam_role.k3s[each.key].name
}

# SSH 없이 SSM Session Manager 접속
resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  for_each = local.k3s_roles

  role       = aws_iam_role.k3s[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Master: K3s 조인 정보 저장, Tailscale 인증 정보 조회
resource "aws_iam_role_policy" "master_parameters" {
  name = "durian-master-parameters"
  role = aws_iam_role.k3s["master"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = "${local.parameter_arn_prefix}/k3s/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "${local.parameter_arn_prefix}/tailscale/*"
      }
    ]
  })
}

# Worker: Master IP/조인 토큰, Tailscale 인증 정보 조회
resource "aws_iam_role_policy" "worker_parameters" {
  name = "durian-worker-parameters"
  role = aws_iam_role.k3s["worker"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "${local.parameter_arn_prefix}/tailscale/*"
        ]
      }
    ]
  })
}
