output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "gha_plan_role_arn" {
  value       = aws_iam_role.gha_plan.arn
  description = "Set as repository variable AWS_PLAN_ROLE_ARN in GitHub"
}

output "gha_apply_role_arn" {
  value       = aws_iam_role.gha_apply.arn
  description = "Set as repository variable AWS_APPLY_ROLE_ARN in GitHub (durian-infra)"
}
