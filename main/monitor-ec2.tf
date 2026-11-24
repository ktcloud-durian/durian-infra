# DURIAN Monitor EC2 — minimal first-stage provisioning.
# Put this file in durian-infra/main/ as monitor-ec2.tf.
# Creates ONE private m7i-flex.large and an SSM-only instance profile.
# Reuses existing subnet, mgmt SG, NAT routing; no monitoring stack installation.
# SecurityOps should approve any additional CloudWatch/SSM secret policies separately.

variable "monitor_enabled" {
  description = "Opt-in: deploy one monitor EC2 in existing private_mon[a] subnet (AZ 2a)"
  type        = bool
  default     = false
}

variable "monitor_instance_type" {
  description = "Monitor EC2 type: 2 vCPU, 8 GiB"
  type        = string
  default     = "m7i-flex.large"
}

variable "monitor_volume_gb" {
  description = "Encrypted gp3 root disk size"
  type        = number
  default     = 30

  validation {
    condition     = var.monitor_volume_gb >= 20
    error_message = "Root disk size must be at least 20 GiB."
  }
}

resource "aws_iam_role" "monitor" {
  count              = var.monitor_enabled ? 1 : 0
  name               = "durian-monitor"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Role = "monitor" }
}

resource "aws_iam_role_policy_attachment" "monitor_ssm" {
  count      = var.monitor_enabled ? 1 : 0
  role       = aws_iam_role.monitor[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Monitor 전용 SSM 읽기 허용 경로
locals {
  monitor_ssm_parameter_arns = [
    for p in [
      "/durian/ops/discord-webhook",
      "/durian/grafana/admin-password",
      "/durian/tailscale/aws-monitor",
      "/durian/k3s/a/master-ip",
      "/durian/k3s/c/master-ip"
    ] : "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter${p}"
  ]
}

# Monitor 통합 읽기 전용 정책
resource "aws_iam_role_policy" "monitor_readonly" {
  count = var.monitor_enabled ? 1 : 0
  name  = "Durian-Monitor-ReadOnly"
  role  = aws_iam_role.monitor[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchReadOnly"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmsForMetric"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "ec2:DescribeRegions"
        ]
        Resource = "*"
      },
      {
        Sid      = "DescribeLambdaLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "LambdaLogsReadOnly"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.me.account_id}:log-group:/aws/lambda/*"
      },
      {
        Sid    = "AllowMonitorSSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = local.monitor_ssm_parameter_arns
      },
      {
        Sid    = "DenyOtherSSMParameters"
        Effect = "Deny"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        NotResource = concat(
          local.monitor_ssm_parameter_arns,
          ["arn:aws:ssm:*::parameter/aws/*"]
        )
      },
      {
        Sid    = "DenySSMParameterPathAndHistory"
        Effect = "Deny"
        Action = [
          "ssm:GetParametersByPath",
          "ssm:GetParameterHistory"
        ]
        Resource = "*"
      }
    ]
  })
}
resource "aws_iam_instance_profile" "monitor" {
  count = var.monitor_enabled ? 1 : 0
  name  = "durian-monitor"
  role  = aws_iam_role.monitor[0].name
}

resource "aws_instance" "monitor" {
  count = var.monitor_enabled ? 1 : 0

  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.monitor_instance_type
  subnet_id                   = aws_subnet.private_mon["a"].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.role["mgmt"].id]
  iam_instance_profile        = aws_iam_instance_profile.monitor[0].name

  # Deliberately no user_data: the current team's ROLE=monitor install script
  # exposes 3000/9090/9093 on all interfaces and uses latest image tags.
  # Approved hardened Docker Compose setup is installed later by Ops.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.monitor_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # M7i-flex does not require T3 CPU credit settings.

  lifecycle {
    precondition {
      condition     = var.nat_enabled
      error_message = "Monitor requires approved NAT routing for the existing AZ 2a monitoring subnet."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.monitor_ssm,
    aws_iam_role_policy.monitor_readonly,
    aws_route.private_nat

  ]

  tags = {
    Name = "durian-monitor-a"
    Role = "monitor"
    Site = "aws"
    Tier = "mgmt"
  }
}

output "monitor_ec2" {
  description = "Monitor instance ID and private IP only"
  value = var.monitor_enabled ? {
    id         = aws_instance.monitor[0].id
    private_ip = aws_instance.monitor[0].private_ip
  } : null
}
