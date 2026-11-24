# Two INDEPENDENT K3s clusters: A (2a) and C (2c).
# One EC2 role/instance profile per cluster and node role; no cross-cluster token reads.
# Existing durian-node role/instance profile remain untouched.
locals {
  k3s_roles = {
    for pair in setproduct(sort(keys(local.az_keys)), ["master", "worker"]) :
    "${pair[1]}-${pair[0]}" => { cluster = pair[0], role = pair[1] }
  }
  k3s_parameter_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/durian"
}

resource "aws_iam_role" "k3s" {
  for_each           = local.k3s_roles
  name               = "durian-k3s-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "k3s" {
  for_each = local.k3s_roles
  name     = "durian-k3s-${each.key}"
  role     = aws_iam_role.k3s[each.key].name
}

resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  for_each   = local.k3s_roles
  role       = aws_iam_role.k3s[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "k3s_parameters" {
  for_each = local.k3s_roles
  name     = "durian-k3s-${each.key}-parameters"
  role     = aws_iam_role.k3s[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnClusterJoinData"
        Effect = "Allow"
        Action = each.value.role == "master" ? ["ssm:GetParameter", "ssm:PutParameter"] : ["ssm:GetParameter"]
        Resource = [
          "${local.k3s_parameter_prefix}/k3s/${each.value.cluster}/token",
          "${local.k3s_parameter_prefix}/k3s/${each.value.cluster}/master-ip"
        ]
      },
      {
        Sid      = "RoleSpecificTailscaleKey"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "${local.k3s_parameter_prefix}/tailscale/aws-${each.value.role}"
      },
      {
        # AmazonSSMManagedInstanceCore가 ssm:GetParameter(s)를 Resource "*"로 허용해서,
        # 위 Allow만으로는 다른 클러스터 토큰·보안 웹훅까지 읽힘. 명시적 Deny가 Allow보다 우선 (IAM-01 최소 권한)
        Sid    = "DenyOtherDurianParameters"
        Effect = "Deny"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
        NotResource = [
          "${local.k3s_parameter_prefix}/k3s/${each.value.cluster}/token",
          "${local.k3s_parameter_prefix}/k3s/${each.value.cluster}/master-ip",
          "${local.k3s_parameter_prefix}/tailscale/aws-${each.value.role}",
          "arn:aws:ssm:*::parameter/aws/*" # AWS 공개 파라미터(AMI 등)
        ]
      }
    ]
  })
}

# Optional for parameters encrypted with a customer-managed KMS key.
# If set, the key policy must also allow the EC2 roles. Empty => default aws/ssm key.
variable "aws_k3s_ssm_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for K3s/Tailscale SSM SecureStrings"
  type        = string
  default     = ""
}

resource "aws_iam_role_policy" "k3s_parameter_kms" {
  for_each = var.aws_k3s_ssm_kms_key_arn == "" ? {} : local.k3s_roles
  name     = "durian-k3s-${each.key}-ssm-kms"
  role     = aws_iam_role.k3s[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = each.value.role == "master" ? ["kms:Decrypt", "kms:Encrypt"] : ["kms:Decrypt"]
      Resource = var.aws_k3s_ssm_kms_key_arn
    }]
  })
}
