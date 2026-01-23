variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "Restic Docker image"
  type        = string
  default     = "restic/restic:0.18.1"
}
