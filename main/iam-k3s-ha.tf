# DURIAN K3s HA - SSM read permissions
# Server token and datastore credentials are master-only.
# Parameters will be provisioned separately after approval.

resource "aws_iam_role_policy" "k3s_ha_master_read" {
  name = "durian-k3s-ha-master-read"
  role = aws_iam_role.k3s["master"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "${local.parameter_arn_prefix}/k3s/ha/server-token",
        "${local.parameter_arn_prefix}/k3s/ha/agent-token",
        "${local.parameter_arn_prefix}/k3s/ha/datastore-endpoint",
        "${local.parameter_arn_prefix}/k3s/ha/registration-endpoint"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "k3s_ha_worker_read" {
  name = "durian-k3s-ha-worker-read"
  role = aws_iam_role.k3s["worker"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "${local.parameter_arn_prefix}/k3s/ha/agent-token",
        "${local.parameter_arn_prefix}/k3s/ha/registration-endpoint"
      ]
    }]
  })
}
