variable "region" {
  type    = string
  default = "ap-northeast-2"
}

# EC2 목록. 서버를 추가/삭제하려면 terraform.tfvars의 이 맵만 수정한다.
# role: "k3s"    = k3s + ArgoCD 설치 (서비스 클러스터)
#       "runner" = Docker/Git/swap 준비 (GitHub runner 등록은 수동)
variable "instances" {
  type = map(object({
    role          = string
    instance_type = string
    volume_gb     = optional(number, 30)
    ami_id        = optional(string) # 지정하면 이 AMI로 부팅하고 user_data는 실행하지 않음
  }))
  default = {
    k3s = { role = "k3s", instance_type = "m7i-flex.large", ami_id = "ami-0427d6051617172b0" }
  }
}

variable "subnet_id" {
  type        = string
  description = "비워두면 durian VPC의 첫 public 서브넷. 인스턴스 타입이 AZ에서 안 되면 직접 지정."
  default     = null
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Kubernetes API(6443)를 열 IP/32 목록. 비우면 외부 노출 없음(SSM/Tailscale 사용)."
  default     = []
}

variable "argocd_version" {
  type        = string
  description = "ArgoCD 매니페스트 ref (stable 또는 v2.x.y 태그)"
  default     = "stable"
}

variable "buckets" {
  type        = set(string)
  description = "만들 S3 버킷의 용도 이름 목록. 비어 있으면 아무것도 만들지 않는다."
  default     = []
}

variable "name" {
  type    = string
  default = "durian"
}

variable "vpc_cidr" {
  type        = string
  description = "온프레미스(OpenStack) 대역과 겹치지 않아야 함"
  default     = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2c"]
}
