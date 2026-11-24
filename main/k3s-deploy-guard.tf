# No AWS EC2 deployments until K3s, outbound network and GitOps versions are approved.
variable "aws_k3s_version" {
  description = "Pinned K3s version (example syntax: v1.34.3+k3s1)"
  type        = string
  default     = ""
}

variable "aws_k3s_bootstrap_approved" {
  type    = bool
  default = false
}

resource "terraform_data" "aws_k3s_guard" {
  count = var.aws_k3s_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition = (
        join(",", sort(keys(local.az_keys))) == "a,c" &&
        var.aws_k3s_master_count == 2 &&
        var.aws_k3s_worker_desired == 2 &&
        var.aws_k3s_datastore == "sqlite" &&
        var.aws_k3s_bootstrap_approved &&
        var.aws_k3s_network_approved &&
        can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.aws_k3s_version)) &&
        trimspace(var.aws_k3s_argocd_chart_version) != "" &&
        var.aws_k3s_image_registry == "ghcr" &&
        alltrue([for v in values(local.k3s_master_user_data) : length(v) <= 16384]) &&
        alltrue([for v in values(local.k3s_worker_user_data) : length(v) <= 16384])
      )
      error_message = "K3s requires A/C AZs, SQLite, approved bootstrap+private egress, pinned K3s+Argo CD, GHCR, and <=16KiB User Data."
    }
  }
}
