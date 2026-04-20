variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Valkey image tag"
  type        = string
  # renovate: datasource=docker depName=valkey/valkey
  default = "8.1-alpine3.21"
}
