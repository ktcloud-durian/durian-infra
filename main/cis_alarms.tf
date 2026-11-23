# 6) CIS AWS Foundations 5.1~5.15 — CloudTrail 로그 지표 필터 + CloudWatch 경보 (보안 기준서 LOG-05·07 보강)
# 담당: 보안(송윤지)
#
# 왜 필요한가: 실시간 알림은 EventBridge → sec_responder(detection*.tf)가 하지만,
#   CIS·Prowler는 "CloudTrail → CloudWatch Logs → 지표 필터 → 경보"가 있어야 통과로 봄 (1차 Prowler에서 5.x 15개 FAIL)
# 동작: CloudTrail이 서울 로그 그룹에도 로그를 보냄 → 필터가 위험 이벤트를 셈 → 5분에 1건 이상이면 경보 ALARM
#   경보는 기록·대시보드(Grafana CloudWatch 패널)용. Discord 알림은 기존 EventBridge 규칙이 계속 담당
# 비용: 지표 필터 무료, 경보 15개(월 10개까지 무료, 넘는 건 개당 약 $0.10), 로그 수집은 관리 이벤트만이라 프리 티어 안쪽
# 패턴은 CIS 7.0과 Prowler 검사(cloudwatch_log_metric_filter_*) 문구를 그대로 따름. 바꾸면 Prowler가 다시 FAIL로 봄

variable "cis_alarm_actions" {
  description = "CIS 경보가 ALARM이 될 때 보낼 SNS 주제 ARN 목록. 비우면 경보 상태만 남김 (알림은 EventBridge 규칙이 담당)"
  type        = list(string)
  default     = []
}

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${var.name}"
  retention_in_days = 30 # 장기 보관은 S3(cloudtrail.tf)
}

# CloudTrail이 로그 그룹에 쓸 수 있는 역할 (이 트레일에서만 쓰게 SourceArn으로 제한)
data "aws_iam_policy_document" "trail_cwl_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "trail_cwl" {
  name               = "${var.name}-cloudtrail-to-cwl"
  assume_role_policy = data.aws_iam_policy_document.trail_cwl_assume.json
}

data "aws_iam_policy_document" "trail_cwl" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "trail_cwl" {
  name   = "write-trail-log-group"
  role   = aws_iam_role.trail_cwl.id
  policy = data.aws_iam_policy_document.trail_cwl.json
}

locals {
  cis_namespace = "${var.name}/CIS"

  # 키 = 지표 이름. cis = CIS 7.0 항목 번호
  cis_filters = {
    UnauthorizedAPICalls = {
      cis     = "5.1"
      desc    = "권한 없는 API 호출"
      pattern = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
    }
    ConsoleSignInWithoutMFA = {
      cis     = "5.2"
      desc    = "MFA 없이 콘솔 로그인"
      pattern = "{ ($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed != \"Yes\") && ($.userIdentity.type = \"IAMUser\") && ($.responseElements.ConsoleLogin = \"Success\") }"
    }
    RootAccountUsage = {
      cis     = "5.3"
      desc    = "루트 계정 사용"
      pattern = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
    }
    IAMPolicyChanges = {
      cis     = "5.4"
      desc    = "IAM 정책 변경"
      pattern = "{ ($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = DeletePolicyVersion) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = AttachUserPolicy) || ($.eventName = DetachUserPolicy) || ($.eventName = AttachGroupPolicy) || ($.eventName = DetachGroupPolicy) }"
    }
    CloudTrailConfigChanges = {
      cis     = "5.5"
      desc    = "CloudTrail 설정 변경"
      pattern = "{ ($.eventName = CreateTrail) || ($.eventName = UpdateTrail) || ($.eventName = DeleteTrail) || ($.eventName = StartLogging) || ($.eventName = StopLogging) }"
    }
    ConsoleAuthFailures = {
      cis     = "5.6"
      desc    = "콘솔 로그인 실패"
      pattern = "{ ($.eventName = ConsoleLogin) && ($.errorMessage = \"Failed authentication\") }"
    }
    KMSKeyDisableOrDeletion = {
      cis     = "5.7"
      desc    = "KMS 키 비활성화·삭제 예약"
      pattern = "{ ($.eventSource = kms.amazonaws.com) && (($.eventName = DisableKey) || ($.eventName = ScheduleKeyDeletion)) }"
    }
    S3BucketPolicyChanges = {
      cis     = "5.8"
      desc    = "S3 버킷 정책 변경"
      pattern = "{ ($.eventSource = s3.amazonaws.com) && (($.eventName = PutBucketAcl) || ($.eventName = PutBucketPolicy) || ($.eventName = PutBucketCors) || ($.eventName = PutBucketLifecycle) || ($.eventName = PutBucketReplication) || ($.eventName = DeleteBucketPolicy) || ($.eventName = DeleteBucketCors) || ($.eventName = DeleteBucketLifecycle) || ($.eventName = DeleteBucketReplication)) }"
    }
    AWSConfigChanges = {
      cis     = "5.9"
      desc    = "AWS Config 설정 변경"
      pattern = "{ ($.eventSource = config.amazonaws.com) && (($.eventName = StopConfigurationRecorder) || ($.eventName = DeleteDeliveryChannel) || ($.eventName = PutDeliveryChannel) || ($.eventName = PutConfigurationRecorder)) }"
    }
    SecurityGroupChanges = {
      cis     = "5.10"
      desc    = "보안그룹 변경"
      pattern = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupEgress) || ($.eventName = CreateSecurityGroup) || ($.eventName = DeleteSecurityGroup) }"
    }
    NACLChanges = {
      cis     = "5.11"
      desc    = "네트워크 ACL 변경"
      pattern = "{ ($.eventName = CreateNetworkAcl) || ($.eventName = CreateNetworkAclEntry) || ($.eventName = DeleteNetworkAcl) || ($.eventName = DeleteNetworkAclEntry) || ($.eventName = ReplaceNetworkAclEntry) || ($.eventName = ReplaceNetworkAclAssociation) }"
    }
    NetworkGatewayChanges = {
      cis     = "5.12"
      desc    = "네트워크 게이트웨이 변경"
      pattern = "{ ($.eventName = CreateCustomerGateway) || ($.eventName = DeleteCustomerGateway) || ($.eventName = AttachInternetGateway) || ($.eventName = CreateInternetGateway) || ($.eventName = DeleteInternetGateway) || ($.eventName = DetachInternetGateway) }"
    }
    RouteTableChanges = {
      cis     = "5.13"
      desc    = "라우팅 테이블 변경"
      pattern = "{ ($.eventSource = ec2.amazonaws.com) && (($.eventName = CreateRoute) || ($.eventName = CreateRouteTable) || ($.eventName = ReplaceRoute) || ($.eventName = ReplaceRouteTableAssociation) || ($.eventName = DeleteRouteTable) || ($.eventName = DeleteRoute) || ($.eventName = DisassociateRouteTable)) }"
    }
    VPCChanges = {
      cis     = "5.14"
      desc    = "VPC 변경"
      pattern = "{ ($.eventName = CreateVpc) || ($.eventName = DeleteVpc) || ($.eventName = ModifyVpcAttribute) || ($.eventName = AcceptVpcPeeringConnection) || ($.eventName = CreateVpcPeeringConnection) || ($.eventName = DeleteVpcPeeringConnection) || ($.eventName = RejectVpcPeeringConnection) || ($.eventName = AttachClassicLinkVpc) || ($.eventName = DetachClassicLinkVpc) || ($.eventName = DisableVpcClassicLink) || ($.eventName = EnableVpcClassicLink) }"
    }
    OrganizationsChanges = {
      cis     = "5.15"
      desc    = "Organizations 변경 (조직은 없지만 생기면 바로 잡도록)"
      pattern = "{ ($.eventSource = organizations.amazonaws.com) && (($.eventName = AcceptHandshake) || ($.eventName = AttachPolicy) || ($.eventName = CancelHandshake) || ($.eventName = CreateAccount) || ($.eventName = CreateOrganization) || ($.eventName = CreateOrganizationalUnit) || ($.eventName = CreatePolicy) || ($.eventName = DeclineHandshake) || ($.eventName = DeleteOrganization) || ($.eventName = DeleteOrganizationalUnit) || ($.eventName = DeletePolicy) || ($.eventName = EnableAllFeatures) || ($.eventName = EnablePolicyType) || ($.eventName = InviteAccountToOrganization) || ($.eventName = LeaveOrganization) || ($.eventName = DetachPolicy) || ($.eventName = DisablePolicyType) || ($.eventName = MoveAccount) || ($.eventName = RemoveAccountFromOrganization) || ($.eventName = UpdateOrganizationalUnit) || ($.eventName = UpdatePolicy)) }"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "cis" {
  for_each       = local.cis_filters
  name           = "${var.name}-cis-${each.key}"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = local.cis_namespace
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cis" {
  for_each            = local.cis_filters
  alarm_name          = "${var.name}-cis-${each.value.cis}-${each.key}"
  alarm_description   = "CIS ${each.value.cis} ${each.value.desc}"
  namespace           = local.cis_namespace
  metric_name         = aws_cloudwatch_log_metric_filter.cis[each.key].metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.cis_alarm_actions
}
