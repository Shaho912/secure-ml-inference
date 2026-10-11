variable "project" {
  description = "Name prefix and tag for all resources."
  type        = string
  default     = "secure-ml-inference"
}

variable "alert_email" {
  description = "Email that receives billing alerts. Set it in terraform.tfvars (gitignored), never in code."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "monthly_limit_usd" {
  description = "Alarm threshold and budget limit, in USD per month."
  type        = number
  default     = 10
}
