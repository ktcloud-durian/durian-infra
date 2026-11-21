# DURIAN independent AWS K3s clusters: A in 2a, C in 2c.
# Everything below remains opt-in, and nothing launches at default values.
variable "aws_k3s_enabled" {
  description = "Create new K3s Master/Worker EC2 resources (requires explicit guard approvals)"
  type        = bool
  default     = false
}

variable "aws_k3s_master_count" {
  description = "Required master count: exactly one per cluster/AZ"
  type        = number
  default     = 2
  validation {
    condition     = var.aws_k3s_master_count == 2
    error_message = "DURIAN independent design requires exactly two Masters."
  }
}

variable "aws_k3s_worker_desired" {
  description = "Required total Worker count: exactly one per AZ"
  type        = number
  default     = 2
  validation {
    condition     = var.aws_k3s_worker_desired == 2
    error_message = "DURIAN independent design requires exactly two Workers."
  }
}

variable "aws_k3s_datastore" {
  description = "Per-cluster local K3s datastore: sqlite (NOT external MariaDB HA)"
  type        = string
  default     = "sqlite"
  validation {
    condition     = var.aws_k3s_datastore == "sqlite"
    error_message = "This DURIAN layout uses two independent SQLite control planes."
  }
}

variable "aws_k3s_pod_cidr" {
  description = "Pod CIDR for each independent cluster; not advertised via Tailscale"
  type        = string
  default     = "10.52.0.0/16"
}

variable "aws_k3s_service_cidr" {
  description = "Service CIDR for each independent cluster; not advertised via Tailscale"
  type        = string
  default     = "10.53.0.0/16"
}

variable "aws_k3s_master_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "aws_k3s_worker_instance_type" {
  type    = string
  default = "t3.small"
}

variable "aws_k3s_image_registry" {
  description = "Application image source (ECR bootstrap not yet integrated into team install.sh)"
  type        = string
  default     = "ghcr"
  validation {
    condition     = contains(["ghcr", "ecr"], var.aws_k3s_image_registry)
    error_message = "Registry must be ghcr or ecr."
  }
}

variable "aws_k3s_argocd_chart_version" {
  description = "Pinned argo/argo-cd chart version, required before enabling K3s bootstrap"
  type        = string
  default     = ""
}

variable "aws_k3s_network_approved" {
  description = "Set true ONLY after validating private subnet outbound access (NAT/approved path)"
  type        = bool
  default     = false
}

variable "aws_k3s_require_tailscale" {
  description = "Fail bootstrap if Tailscale enrollment was skipped or unsuccessful"
  type        = bool
  default     = true
}
