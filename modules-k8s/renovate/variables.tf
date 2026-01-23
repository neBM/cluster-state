variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "Renovate Docker image"
  type        = string
  default     = "ghcr.io/renovatebot/renovate:39"
}
