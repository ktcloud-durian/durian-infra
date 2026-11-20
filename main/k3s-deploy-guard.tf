# DURIAN K3s deployment safety guard.
# No K3s deployment before HA bootstrap is approved.

variable "aws_k3s_version" {
  description = "Pinned K3s version"
  type        = string
  default     = ""
}

variable "aws_k3s_bootstrap_approved" {
  description = "Explicit deployment readiness switch"
  type        = bool
  default     = false
}

resource "terraform_data" "aws_k3s_guard" {
  count = var.aws_k3s_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition = (
        var.aws_k3s_datastore == "external" &&
        var.aws_k3s_bootstrap_approved &&
        trimspace(var.aws_k3s_version) != "" &&
        (
          var.aws_k3s_image_registry == "ghcr" ||
          (
            trimspace(var.aws_k3s_ecr_s3_bucket) != "" &&
            trimspace(var.aws_k3s_ecr_s3_key) != ""
          )
        ) &&
        floor(length(trim(base64encode(local.k3s_master_user_data), "=")) * 3 / 4) <= 16384 &&
        floor(length(trim(base64encode(local.k3s_worker_user_data), "=")) * 3 / 4) <= 16384
      )

      error_message = "K3s requires approved external datastore, bootstrap and pinned version."
    }
  }
}
