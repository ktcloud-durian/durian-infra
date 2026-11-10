variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "github_owner" {
  type        = string
  description = "GitHub user or organization that owns the repositories"
  default     = "Jaewoo2580"
}

variable "github_owner_id" {
  type        = string
  description = "Numeric GitHub account ID of the owner (GitHub now puts it in the OIDC sub claim: repo:<owner>@<owner_id>/<repo>@<repo_id>:...)"
  default     = "69108899"
}

variable "github_repos" {
  type        = list(string)
  description = "Repositories allowed to assume the read-only plan role through OIDC"
  default     = ["durian-infra"]
}

variable "infra_repo" {
  type        = string
  description = "Repository whose production Environment may assume the apply role"
  default     = "durian-infra"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for Terraform state. Empty = durian-tfstate-<account id>"
  default     = ""
}

variable "force_destroy_state" {
  type        = bool
  description = "Allow deleting the state bucket together with all object versions (teardown only)"
  default     = false
}
