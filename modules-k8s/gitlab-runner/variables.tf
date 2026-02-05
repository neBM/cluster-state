variable "namespace" {
  description = "Kubernetes namespace for runner deployments"
  type        = string
  default     = "default"
}

variable "job_namespace" {
  description = "Kubernetes namespace where CI job pods are created"
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
  default = "v18.8.0"
}

variable "privileged_jobs" {
  description = "Allow job pods to run in privileged mode (needed for Podman container builds)"
  type        = bool
  default     = true
}
