variable "name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "az" {
  type        = string
  description = "Availability zone, e.g. ap-northeast-2a"
}
