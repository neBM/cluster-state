variable "namespace" {
  description = "Namespace for the service account"
  type        = string
  default     = "default"
}

variable "service_account_name" {
  description = "Name of the service account"
  type        = string
  default     = "terraform-ci"
}
