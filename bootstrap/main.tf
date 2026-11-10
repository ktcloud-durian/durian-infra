data "aws_caller_identity" "current" {}

locals {
  state_bucket = var.state_bucket_name != "" ? var.state_bucket_name : "durian-tfstate-${data.aws_caller_identity.current.account_id}"
  # plan role: pull requests and main branch only (no tags, no other branches)
  repo_subs = flatten([
    for r in var.github_repos : [
      "repo:${var.github_owner}@${var.github_owner_id}/${r}@*:pull_request",
      "repo:${var.github_owner}@${var.github_owner_id}/${r}@*:ref:refs/heads/main",
    ]
  ])
}

# ---------- Terraform remote state (S3, native locking via use_lockfile) ----------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- GitHub Actions OIDC (no long-lived AWS keys) ----------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.repo_subs
    }
  }
}

# Read-only role for `terraform plan` in CI. Apply stays manual (local, SSO).
resource "aws_iam_role" "gha_plan" {
  name               = "durian-gha-plan"
  assume_role_policy = data.aws_iam_policy_document.gha_trust.json
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "gha_state" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
}

resource "aws_iam_role_policy" "gha_state" {
  name   = "tfstate-access"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.gha_state.json
}

# ---------- Apply role: only jobs running in the "production" Environment ----------
data "aws_iam_policy_document" "gha_apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/${var.infra_repo}@*:environment:production"]
    }
  }
}

resource "aws_iam_role" "gha_apply" {
  name               = "durian-gha-apply"
  assume_role_policy = data.aws_iam_policy_document.gha_apply_trust.json
}

# Broad on purpose for the learning phase. Narrow this to the services actually managed later.
resource "aws_iam_role_policy_attachment" "gha_apply_admin" {
  role       = aws_iam_role.gha_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
