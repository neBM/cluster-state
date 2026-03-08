variable "app_name" {
  type        = string
  description = "Application name"
  default     = "alloy"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_tag" {
  type        = string
  description = "Grafana Alloy container image tag"
  default     = "v1.7.1"
}

variable "loki_url" {
  type        = string
  description = "Loki push API URL (e.g. http://loki.default.svc.cluster.local:3100/loki/api/v1/push)"
}

variable "memory_request" {
  type        = string
  description = "Memory request per DaemonSet pod"
  default     = "128Mi"
}

variable "memory_limit" {
  type        = string
  description = "Memory limit per DaemonSet pod"
  default     = "384Mi"
}

variable "cpu_request" {
  type        = string
  description = "CPU request per DaemonSet pod"
  default     = "50m"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit per DaemonSet pod"
  default     = "200m"
}
