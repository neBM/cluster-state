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

variable "cache_s3_endpoint" {
  description = "MinIO/S3 endpoint for runner shared cache (host:port, no scheme)"
  type        = string
  default     = "minio-api.default.svc.cluster.local:9000"
}

variable "cache_s3_bucket" {
  description = "S3 bucket name for runner shared cache"
  type        = string
  default     = "gitlab-runner-cache"
}

variable "cache_s3_secret_name" {
  description = "Kubernetes secret containing accesskey and secretkey for cache"
  type        = string
  default     = "gitlab-runner-cache-s3"
}

variable "amd64_concurrent" {
  description = "Max concurrent jobs for the amd64 runner (1 node: Hestia)"
  type        = number
  default     = 1
}

variable "arm64_concurrent" {
  description = "Max concurrent jobs for the arm64 runner (2 nodes: Heracles, Nyx)"
  type        = number
  default     = 2
}
