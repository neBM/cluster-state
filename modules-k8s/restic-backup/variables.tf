variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "Restic Docker image name"
  type        = string
  default     = "restic/restic"
}

variable "image_tag" {
  description = "Restic Docker image tag"
  type        = string
  # renovate: datasource=docker depName=restic/restic
  default = "0.18.1"
}
