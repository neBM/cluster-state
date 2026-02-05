variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "Renovate Docker image name"
  type        = string
  default     = "ghcr.io/renovatebot/renovate"
}

variable "image_tag" {
  description = "Renovate Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
  default = "43"
}
