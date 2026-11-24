# AZ-pinned Worker ASGs: Worker A can only join Master A; C can only join C.
# NOTE: an ASG will replace stopped Workers; scale desired/min to zero for cost control.
resource "aws_launch_template" "k3s_worker" {
  for_each = var.aws_k3s_enabled ? local.az_keys : {}
  depends_on = [
    terraform_data.aws_k3s_guard,
    aws_iam_role_policy.k3s_parameters,
    aws_iam_role_policy_attachment.k3s_ssm
  ]

  name_prefix   = "durian-k3s-worker-${each.key}-"
  image_id      = data.aws_ssm_parameter.ubuntu.value
  instance_type = var.aws_k3s_worker_instance_type
  user_data     = base64encode(local.k3s_worker_user_data[each.key])

  iam_instance_profile {
    name = aws_iam_instance_profile.k3s["worker-${each.key}"].name
  }
  vpc_security_group_ids = [aws_security_group.k3s_worker[each.key].id]
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "durian-k3s-worker-${each.key}"
      Role    = "worker"
      Cluster = each.key
    }
  }
}

resource "aws_autoscaling_group" "k3s_worker" {
  for_each            = var.aws_k3s_enabled ? local.az_keys : {}
  depends_on          = [terraform_data.aws_k3s_guard, aws_instance.k3s_master]
  name                = "durian-k3s-worker-asg-${each.key}"
  min_size            = 1
  desired_capacity    = 1
  max_size            = 1
  vpc_zone_identifier = [aws_subnet.private_app[each.key].id]
  target_group_arns   = var.aws_alb_enabled ? [aws_lb_target_group.web[0].arn] : []
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.k3s_worker[each.key].id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "durian-k3s-worker-${each.key}"
    propagate_at_launch = true
  }
  tag {
    key                 = "Cluster"
    value               = each.key
    propagate_at_launch = true
  }
}
