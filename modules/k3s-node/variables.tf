variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "volume_size_gb" {
  type    = number
  default = 60
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the Kubernetes API (6443). Empty = not exposed (use SSM port forwarding)."
  default     = []
}
