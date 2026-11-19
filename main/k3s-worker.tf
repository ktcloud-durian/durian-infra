# DURIAN AWS K3s Worker ASG - Draft
# Worker 2 across AZ 2a / 2c
# K3s bootstrap and ECR credentials are pending.
# Deployment disabled by aws_k3s_enabled = false.

resource "aws_launch_template" "k3s_worker" {
  user_data  = base64encode(local.k3s_worker_user_data)
  depends_on = [terraform_data.aws_k3s_guard]
  for_each   = var.aws_k3s_enabled ? { main = true } : {}

  name_prefix   = "durian-k3s-worker-"
  image_id      = data.aws_ssm_parameter.ubuntu.value
  instance_type = var.aws_k3s_worker_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.k3s["worker"].name
  }

  vpc_security_group_ids = [
    aws_security_group.role["worker"].id,
    aws_security_group.role["node"].id
  ]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "durian-k3s-worker"
      Role = "worker"
    }
  }

  # User Data will be added after K3s HA design approval.
}

resource "aws_autoscaling_group" "k3s_worker" {
  target_group_arns = var.aws_alb_enabled ? [aws_lb_target_group.web[0].arn] : []
  depends_on        = [terraform_data.aws_k3s_guard]
  for_each          = var.aws_k3s_enabled ? { main = true } : {}

  name = "durian-k3s-worker-asg"

  min_size         = var.aws_k3s_worker_desired
  desired_capacity = var.aws_k3s_worker_desired
  max_size         = var.aws_k3s_worker_desired + 1

  vpc_zone_identifier = [
    for az in sort(keys(local.az_keys)) :
    aws_subnet.private_app[az].id
  ]

  health_check_type = "EC2"

  launch_template {
    id      = aws_launch_template.k3s_worker[each.key].id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "durian-k3s-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "worker"
    propagate_at_launch = true
  }
}
