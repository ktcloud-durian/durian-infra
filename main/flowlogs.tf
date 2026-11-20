# LOG-02, CIS EC2.6 — VPC Flow Logs (누가 어디로 접속했는지 네트워크 기록)
# CloudTrail 버킷의 vpc-flow-logs/ 아래에 쌓음. 보관 기간은 트레일 버킷 수명 주기(90일)를 따름
# 담당: 보안(송윤지)

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = "${aws_s3_bucket.trail.arn}/vpc-flow-logs/"
  max_aggregation_interval = 600

  tags = { Name = "${var.name}-vpc-flow-logs" }

  depends_on = [aws_s3_bucket_policy.trail]
}
