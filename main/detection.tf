# 탐지·자동 대응 (보안 기준서 LOG-05·06, 시연 4·5). 담당: 보안(송윤지)
# CloudTrail 트레일(cloudtrail.tf)이 있어야 EventBridge가 API 호출 이벤트를 받음
# 흐름: SG 인바운드 변경 → EventBridge → Lambda(sec_responder) → (삭제) + Discord 보안 채널
# CloudTrail 무력화(detection_tamper.tf), IAM 변경·루트 로그인(detection_global.tf, us-east-1)은 알림만
# GuardDuty 규칙은 계정에서 GuardDuty를 지원하지 않아(EX-10) 이벤트가 오지 않음. 계정을 바꾸면 그대로 쓸 수 있게 남겨 둠

data "archive_file" "sec_responder" {
  type        = "zip"
  source_file = "${path.module}/lambda/sec_responder/index.py"
  output_path = "${path.module}/.build/sec_responder.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sec_responder" {
  name               = "${var.name}-sec-responder"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# 최소 권한: 규칙 조회, 인바운드 규칙 삭제, 웹훅 파라미터 하나 읽기, 자기 로그 쓰기
data "aws_iam_policy_document" "sec_responder" {
  statement {
    sid       = "ReadSecurityGroupRules"
    actions   = ["ec2:DescribeSecurityGroupRules"]
    resources = ["*"] # Describe 계열은 리소스 지정이 안 됨
  }
  statement {
    sid       = "RevokeIngress"
    actions   = ["ec2:RevokeSecurityGroupIngress"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.me.account_id}:security-group/*"]
  }
  statement {
    sid       = "ReadWebhookParam"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter${var.security_webhook_param}"]
  }
  statement {
    sid     = "WriteOwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = concat(
      ["${aws_cloudwatch_log_group.sec_responder.arn}:*"],
      [for lg in aws_cloudwatch_log_group.sec_responder_use1 : "${lg.arn}:*"] # us-east-1 Lambda (detection_global.tf)
    )
  }
}

resource "aws_iam_role_policy" "sec_responder" {
  name   = "sec-responder"
  role   = aws_iam_role.sec_responder.id
  policy = data.aws_iam_policy_document.sec_responder.json
}

resource "aws_cloudwatch_log_group" "sec_responder" {
  name              = "/aws/lambda/${var.name}-sec-responder"
  retention_in_days = 30
}

resource "aws_lambda_function" "sec_responder" {
  function_name    = "${var.name}-sec-responder"
  role             = aws_iam_role.sec_responder.arn
  runtime          = "python3.13"
  handler          = "index.handler"
  filename         = data.archive_file.sec_responder.output_path
  source_code_hash = data.archive_file.sec_responder.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      MODE          = var.auto_revoke_mode
      EXCEPTIONS    = jsonencode(var.public_ingress_exceptions)
      WEBHOOK_PARAM = var.security_webhook_param
    }
  }

  depends_on = [aws_cloudwatch_log_group.sec_responder, aws_iam_role_policy.sec_responder]
}

# 1) 보안그룹 인바운드 변경 (콘솔·CLI·Terraform 모두)
resource "aws_cloudwatch_event_rule" "sg_ingress_change" {
  name        = "${var.name}-sg-ingress-change"
  description = "SG 인바운드 추가·수정 → sec_responder"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AuthorizeSecurityGroupIngress", "ModifySecurityGroupRules"]
    }
  })
}

resource "aws_cloudwatch_event_target" "sg_ingress_change" {
  rule = aws_cloudwatch_event_rule.sg_ingress_change.name
  arn  = aws_lambda_function.sec_responder.arn
}

resource "aws_lambda_permission" "sg_ingress_change" {
  statement_id  = "AllowEventBridgeSgIngress"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sec_responder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sg_ingress_change.arn
}

# 2) GuardDuty 탐지 — 심각도 4(중간) 이상만 알림
resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "${var.name}-guardduty-finding"
  description = "GuardDuty 심각도 4 이상 → sec_responder(알림)"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 4] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_finding" {
  rule = aws_cloudwatch_event_rule.guardduty_finding.name
  arn  = aws_lambda_function.sec_responder.arn
}

resource "aws_lambda_permission" "guardduty_finding" {
  statement_id  = "AllowEventBridgeGuardDuty"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sec_responder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_finding.arn
}

# 3) 자동 대응이 고장 나면 알아야 함 — Lambda 오류 경보 (Grafana CloudWatch 패널에서 확인)
resource "aws_cloudwatch_metric_alarm" "sec_responder_errors" {
  alarm_name          = "${var.name}-sec-responder-errors"
  alarm_description   = "자동 대응 Lambda 실패"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.sec_responder.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
