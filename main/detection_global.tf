# 5) IAM 변경·루트 로그인 실시간 알림 (보안 기준서 LOG-07, 시연 S3·S5). 담당: 보안(송윤지)
# IAM·로그인 같은 글로벌 이벤트는 us-east-1에만 기록되므로 그 리전에 규칙과 Lambda를 따로 둠
# us-east-1 규칙이 서울 Lambda를 직접 부르는 건 리전 간 기능이라 쓰지 않고, 같은 코드의 Lambda를 us-east-1에 하나 더 둠
# 알림만 함 (MODE=notify 고정). 웹훅은 서울 SSM 값을 그대로 읽음 (WEBHOOK_REGION)
#
# 켜기 전 조건: us-east-1 이벤트를 기록하는 트레일이 있어야 EventBridge가 받음 (cloudtrail.tf의 멀티 리전 트레일)
# 계정 유형(새 가입 방식)에서 us-east-1 리소스 생성이 막히면 false로 두고 LOG-07은 주간 점검으로 대신함

variable "global_detection_enabled" {
  description = "us-east-1에 IAM·루트 로그인 탐지 규칙과 Lambda를 만들지. 멀티 리전 트레일이 적용된 뒤 true로 켬"
  type        = bool
  default     = false
}

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "durian"
      ManagedBy = "terraform"
    }
  }
}

locals {
  global_detection = var.global_detection_enabled ? { on = true } : {}
}

resource "aws_cloudwatch_log_group" "sec_responder_use1" {
  provider          = aws.use1
  for_each          = local.global_detection
  name              = "/aws/lambda/${var.name}-sec-responder"
  retention_in_days = 30
}

# 역할(IAM)은 글로벌이라 서울 Lambda와 같은 역할을 씀. 로그 쓰기 권한은 detection.tf 정책에 us-east-1 로그 그룹을 추가함
resource "aws_lambda_function" "sec_responder_use1" {
  provider         = aws.use1
  for_each         = local.global_detection
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
      MODE           = "notify"
      EXCEPTIONS     = "{}"
      WEBHOOK_PARAM  = var.security_webhook_param
      WEBHOOK_REGION = var.region
    }
  }

  depends_on = [aws_cloudwatch_log_group.sec_responder_use1, aws_iam_role_policy.sec_responder]
}

# IAM 권한 부여·키 생성·사용자 생성 (실패한 호출도 알림: 막힌 키 생성 시도도 시연 S5에서 보임)
resource "aws_cloudwatch_event_rule" "iam_change" {
  provider    = aws.use1
  for_each    = local.global_detection
  name        = "${var.name}-iam-change"
  description = "IAM 권한 부여·액세스 키·사용자 생성 → sec_responder(알림)"
  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName = [
        "AttachUserPolicy", "AttachRolePolicy", "AttachGroupPolicy",
        "PutUserPolicy", "PutRolePolicy", "PutGroupPolicy",
        "CreateAccessKey", "CreateUser", "CreateLoginProfile", "AddUserToGroup"
      ]
    }
  })
}

# 루트 계정 콘솔 로그인 (성공·실패 모두)
resource "aws_cloudwatch_event_rule" "root_login" {
  provider    = aws.use1
  for_each    = local.global_detection
  name        = "${var.name}-root-login"
  description = "루트 계정 콘솔 로그인 → sec_responder(알림)"
  event_pattern = jsonencode({
    source        = ["aws.signin"]
    "detail-type" = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = { type = ["Root"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_change" {
  provider = aws.use1
  for_each = local.global_detection
  rule     = aws_cloudwatch_event_rule.iam_change[each.key].name
  arn      = aws_lambda_function.sec_responder_use1[each.key].arn
}

resource "aws_cloudwatch_event_target" "root_login" {
  provider = aws.use1
  for_each = local.global_detection
  rule     = aws_cloudwatch_event_rule.root_login[each.key].name
  arn      = aws_lambda_function.sec_responder_use1[each.key].arn
}

resource "aws_lambda_permission" "iam_change" {
  provider      = aws.use1
  for_each      = local.global_detection
  statement_id  = "AllowEventBridgeIamChange"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sec_responder_use1[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.iam_change[each.key].arn
}

resource "aws_lambda_permission" "root_login" {
  provider      = aws.use1
  for_each      = local.global_detection
  statement_id  = "AllowEventBridgeRootLogin"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sec_responder_use1[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.root_login[each.key].arn
}

resource "aws_cloudwatch_metric_alarm" "sec_responder_use1_errors" {
  provider            = aws.use1
  for_each            = local.global_detection
  alarm_name          = "${var.name}-sec-responder-use1-errors"
  alarm_description   = "us-east-1 자동 알림 Lambda 실패"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.sec_responder_use1[each.key].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
