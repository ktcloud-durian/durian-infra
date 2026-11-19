# DURIAN AWS K3s - Draft Configuration
# Do not enable deployment until HA datastore is decided.

variable "aws_k3s_enabled" {
  description = "Enable new AWS K3s resources"
  type        = bool
  default     = false
}

variable "aws_k3s_master_count" {
  description = "Planned K3s master count"
  type        = number
  default     = 2
}

variable "aws_k3s_worker_desired" {
  description = "Planned ASG worker count"
  type        = number
  default     = 2
}

variable "aws_k3s_datastore" {
  description = "pending / external / embedded_etcd"
  type        = string
  default     = "pending"
}

variable "aws_k3s_pod_cidr" {
  description = "AWS K3s Pod CIDR (draft)"
  type        = string
  default     = "10.52.0.0/16"
}

variable "aws_k3s_service_cidr" {
  description = "AWS K3s Service CIDR (draft)"
  type        = string
  default     = "10.53.0.0/16"
}


variable "aws_k3s_master_instance_type" {
  description = "Master EC2 type - draft"
  type        = string
  default     = "t3.medium"
}
variable "aws_k3s_worker_instance_type" {
  description = "Worker EC2 type - draft"
  type        = string
  default     = "t3.small"
}
