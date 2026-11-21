variable "aws_waf_enabled" {
  description = "Create a regional AWS WAF Web ACL and associate it with the public ALB"
  type        = bool
  default     = false
}

resource "terraform_data" "web_waf_guard" {
  count = var.aws_waf_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = var.aws_alb_enabled
      error_message = "WAF requires aws_alb_enabled=true."
    }
  }
}

resource "aws_wafv2_web_acl" "web" {
  count       = var.aws_waf_enabled && var.aws_alb_enabled ? 1 : 0
  depends_on  = [terraform_data.web_waf_guard]
  name        = "${var.name}-web-waf"
  scope       = "REGIONAL"
  description = "DURIAN demo WAF: Count-only until validated"

  default_action {
    allow {}
  }

  # Initial detection only. Does NOT block traffic until explicitly redesigned.
  rule {
    name     = "AWSManagedCommonRulesCount"
    priority = 10
    override_action {
      count {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "durianCommonRulesCount"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "LoginRateCount"
    priority = 20
    action {
      count {}
    }
    statement {
      rate_based_statement {
        limit                 = 200
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            search_string         = "/login"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "durianLoginRateCount"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "durianWebWaf"
    sampled_requests_enabled   = false
  }
  tags = { Project = "durian" }
}

resource "aws_wafv2_web_acl_association" "web" {
  count        = var.aws_waf_enabled && var.aws_alb_enabled ? 1 : 0
  resource_arn = aws_lb.web[0].arn
  web_acl_arn  = aws_wafv2_web_acl.web[0].arn
}
