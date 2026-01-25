variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "GitLab Runner Docker image name"
  type        = string
  default     = "gitlab/gitlab-runner"
}

variable "image_tag" {
  description = "GitLab Runner Docker image tag"
  type        = string
  # renovate: datasource=docker depName=gitlab/gitlab-runner
  default = "latest"
}
