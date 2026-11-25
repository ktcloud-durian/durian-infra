# New clean Ubuntu AMI per AZ: each Master starts an INDEPENDENT SQLite K3s.
# Existing aws_instance.this["k3s"] is untouched.
resource "aws_instance" "k3s_master" {
  for_each = var.aws_k3s_enabled ? local.az_keys : {}
  depends_on = [
    terraform_data.aws_k3s_guard,
    aws_iam_role_policy.k3s_parameters,
    aws_iam_role_policy_attachment.k3s_ssm
  ]

  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.aws_k3s_master_instance_type
  subnet_id                   = aws_subnet.private_app[each.key].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.k3s_master[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.k3s["master-${each.key}"].name
  user_data_base64            = base64encode(local.k3s_master_user_data[each.key])
  user_data_replace_on_change = true

  # Preserve existing K3s control-plane state.
  lifecycle {
    ignore_changes = [
      ami,
      user_data_base64
    ]
  }

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }
  tags = {
    Name    = "durian-k3s-master-${each.key}"
    Role    = "master"
    Cluster = each.key
  }
}
