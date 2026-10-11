variable "project" {
  description = "Name prefix and tag for all resources."
  type        = string
  default     = "secure-ml-inference"
}

variable "env" {
  description = "Environment tag."
  type        = string
  default     = "demo"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "GitHub repo allowed to deploy, as owner/name."
  type        = string
  default     = "Shaho912/secure-ml-inference"
}

variable "github_environment" {
  description = "GitHub environment whose OIDC tokens may assume the deploy role."
  type        = string
  default     = "production"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one is allowed per URL)."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "task_cpu" {
  description = "Fargate task CPU units (512 = 0.5 vCPU)."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "log_retention_days" {
  type    = number
  default = 7
}
