# 4) CloudTrail 무력화 시도 탐지 (보안 기준서 LOG-05, 시연 S5). 담당: 보안(송윤지)
# GuardDuty는 계정에서 지원하지 않아(EX-10) CloudTrail + EventBridge로 대신함
# StopLogging 호출 자체는 트레일이 멈추기 전에 기록되므로 EventBridge로 들어옴
# 알림만 하고 되돌리지는 않음 (트레일을 다시 켜는 건 사람이 확인 후 Terraform으로)

resource "aws_cloudwatch_event_rule" "cloudtrail_tamper" {
  name        = "${var.name}-cloudtrail-tamper"
  description = "CloudTrail 끄기·삭제·설정 변경 → sec_responder(알림)"
  event_pattern = jsonencode({
    source        = ["aws.cloudtrail"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["cloudtrail.amazonaws.com"]
      eventName   = ["StopLogging", "DeleteTrail", "UpdateTrail", "PutEventSelectors", "PutInsightSelectors"]
    }
  })
}

resource "aws_cloudwatch_event_target" "cloudtrail_tamper" {
  rule = aws_cloudwatch_event_rule.cloudtrail_tamper.name
  arn  = aws_lambda_function.sec_responder.arn
}

resource "aws_lambda_permission" "cloudtrail_tamper" {
  statement_id  = "AllowEventBridgeCloudTrailTamper"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sec_responder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cloudtrail_tamper.arn
}
