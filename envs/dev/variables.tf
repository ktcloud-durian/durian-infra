variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "az" {
  type    = string
  default = "ap-northeast-2a"
}

variable "instance_type" {
  type    = string
  default = "t3.micro" # free-plan accounts only allow free-tier eligible types
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Public IP/32 allowed to reach the Kubernetes API. Leave empty to use SSM only."
  default     = []
}
