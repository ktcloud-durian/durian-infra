# DURIAN AWS K3s Master - Draft
# 2 Masters across AZ 2a / 2c
# HA datastore and bootstrap pending
# Deployment disabled by aws_k3s_enabled = false

resource "aws_instance" "k3s_master" {
  user_data_base64 = base64encode(local.k3s_master_user_data)
  depends_on       = [terraform_data.aws_k3s_guard]
  for_each = var.aws_k3s_enabled ? {
    for key in slice(
      sort(keys(local.az_keys)),
      0,
      var.aws_k3s_master_count
    ) : key => local.az_keys[key]
  } : {}

  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.aws_k3s_master_instance_type
  subnet_id                   = aws_subnet.private_app[each.key].id
  associate_public_ip_address = false

  vpc_security_group_ids = [
    aws_security_group.role["master"].id,
    aws_security_group.role["node"].id
  ]

  iam_instance_profile = aws_iam_instance_profile.k3s["master"].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "durian-k3s-master-${each.key}"
    Role = "master"
  }
}
