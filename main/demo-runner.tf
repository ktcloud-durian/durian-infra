# durian-infra PR용 초안 (실제 반영 전 팀 IaC 구조와 이름 · 서브넷 · 변수 확인 필요). apply는 파이프라인(OIDC)만.
# 평소 중지 상태 운영: 시연 때만 aws ec2 start-instances / stop-instances (Terraform은 상태를 고정하지 않음)
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
  description = "demo runner: no inbound; egress only for SSM/Tailscale/apt"
  vpc_id      = aws_vpc.this.id
}
resource "aws_vpc_security_group_egress_rule" "demo_runner_https" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description = "SSM / Tailscale control / package (EX 등록 필요)"
}
resource "aws_vpc_security_group_egress_rule" "demo_runner_http" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description = "Ubuntu apt (설치 후 제거 검토)"
}
resource "aws_vpc_security_group_egress_rule" "demo_runner_ts_direct" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  description = "Tailscale direct"
}
resource "aws_vpc_security_group_egress_rule" "demo_runner_ts_stun" {
  security_group_id = aws_security_group.demo_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 3478
  to_port           = 3478
  description = "Tailscale STUN"
}

resource "aws_instance" "demo_runner" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
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
