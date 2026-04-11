variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image" {
  type        = string
  description = "Container image (must provide bash and nsenter)"
  default     = "ubuntu"
}

variable "image_tag" {
  type        = string
  description = "Container image tag"
  default     = "24.04"
}
