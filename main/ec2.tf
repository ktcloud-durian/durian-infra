data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# SSM Session Manager용 역할 (SSH/키페어 불필요)
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "durian-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "durian-node"
  role = aws_iam_role.node.name
}

locals {
  user_data = {
    k3s = <<-EOT
      #!/bin/bash
      set -euxo pipefail
      TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
      PUBIP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
      curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 $${PUBIP:+--tls-san $PUBIP}" sh -
      until k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 5; done
      # ArgoCD
      k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f -
      k3s kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/${var.argocd_version}/manifests/install.yaml
    EOT

    runner = <<-EOT
      #!/bin/bash
      set -euxo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io git jq unzip curl
      usermod -aG docker ubuntu
      fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    EOT
  }
}

resource "aws_instance" "this" {
  for_each = var.instances

  ami                    = coalesce(each.value.ami_id, data.aws_ssm_parameter.ubuntu.value)
  instance_type          = each.value.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = each.value.volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data                   = each.value.ami_id == null ? local.user_data[each.value.role] : null
  user_data_replace_on_change = true

  tags = { Name = "durian-${each.key}", Role = each.value.role }
}
