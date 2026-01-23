variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "GitLab Runner Docker image"
  type        = string
  default     = "gitlab/gitlab-runner:latest"
}
