# LOG-05·07: CIS 경보(cis_alarms.tf)가 ALARM이 되면 sec_responder가 Discord 보안 채널로 알림 (알림만)
# SNS 없이 EventBridge 'CloudWatch Alarm State Change'로 받음 (비용 0, 웹훅은 기존 SSM 값 그대로)
# 실시간 규칙과 겹치는 경보는 뺌: 5.3 루트(root-login), 5.4 IAM 정책(iam-change), 5.5 CloudTrail(cloudtrail-tamper), 5.10 보안그룹(sg-ingress-change)
# 담당: 보안(송윤지)

locals {
  cis_alarm_notify = ["5.1", "5.2", "5.6", "5.7", "5.8", "5.9", "5.11", "5.12", "5.13", "5.14", "5.15"]
}

resource "aws_cloudwatch_event_rule" "cis_alarm" {
  name        = "${var.name}-cis-alarm"
  description = "CIS 경보 ALARM → sec_responder(알림)"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [for c in local.cis_alarm_notify : { prefix = "${var.name}-cis-${c}-" }]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "cis_alarm" {
  rule = aws_cloudwatch_event_rule.cis_alarm.name
  arn  = aws_lambda_function.sec_responder.arn
}

resource "aws_lambda_permission" "cis_alarm" {
  statement_id  = "AllowEventBridgeCisAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sec_responder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cis_alarm.arn
}
