# durian-infra PR용 초안 (실제 반영 전 팀 IaC 구조와 이름 · 서브넷 · 변수 확인 필요). apply는 파이프라인(OIDC)만.
# 평소 중지 상태 운영: 시연 때만 aws ec2 start-instances / stop-instances (Terraform은 상태를 고정하지 않음)
# Amazon Linux 2023 최신 AMI (AWS CLI, SSM 에이전트 기본 포함, 패키지 저장소는 HTTPS)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "demo_runner" {
  name               = "durian-demo-runner"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}
resource "aws_iam_role_policy_attachment" "demo_runner_ssm" {
  role       = aws_iam_role.demo_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
data "aws_iam_policy_document" "demo_runner_params" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/durian/demo-runner/*",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/durian/tailscale/aws-demo-runner",
    ]
  }
}
resource "aws_iam_role_policy" "demo_runner_params" {
  role   = aws_iam_role.demo_runner.id
  policy = data.aws_iam_policy_document.demo_runner_params.json
}
resource "aws_iam_instance_profile" "demo_runner" {
  name = "durian-demo-runner"
  role = aws_iam_role.demo_runner.name
}

resource "aws_security_group" "demo_runner" {
  name        = "durian-demo-runner"
  description = "demo runner: no inbound; egress only for SSM/Tailscale/package (HTTPS)"
  vpc_id      = aws_vpc.this.id
}
# EX-?? (신규 등록 필요, 보안 담당): SSM/Tailscale control/package HTTPS via NAT (443/tcp), demo runner
# Scope: resource only. Review 2026-12-04.
#trivy:ignore:AVD-AWS-0104:exp:2026-12-04
resource "aws_vpc_security_group_egress_rule" "demo_runner_https" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  description = "SSM / Tailscale control / package (EX 등록 필요)"
}
# EX-?? (신규 등록 필요, 보안 담당): Tailscale direct via NAT (41641/udp), demo runner
# Scope: resource only. Review 2026-12-04.
#trivy:ignore:AVD-AWS-0104:exp:2026-12-04
resource "aws_vpc_security_group_egress_rule" "demo_runner_ts_direct" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641

  description = "Tailscale direct"
}
# EX-?? (신규 등록 필요, 보안 담당): Tailscale STUN via NAT (3478/udp), demo runner
# Scope: resource only. Review 2026-12-04.
#trivy:ignore:AVD-AWS-0104:exp:2026-12-04
resource "aws_vpc_security_group_egress_rule" "demo_runner_ts_stun" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 3478
  to_port           = 3478

  description = "Tailscale STUN"
}

resource "aws_instance" "demo_runner" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = values(aws_subnet.private_app)[0].id   # 서브넷 이름 · 선택은 팀 구조에 맞게 확인
  vpc_security_group_ids = [aws_security_group.demo_runner.id]
  iam_instance_profile   = aws_iam_instance_profile.demo_runner.name
  associate_public_ip_address = false
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }
  tags = { Name = "durian-demo-runner", Role = "demo-runner" }
}
