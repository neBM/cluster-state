variable "app_name" {
  type        = string
  description = "Application name"
  default     = "kube-state-metrics"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_registry" {
  type        = string
  description = "Container image registry"
  default     = "registry.k8s.io"
}

variable "image_name" {
  type        = string
  description = "Container image name"
  default     = "kube-state-metrics/kube-state-metrics"
}

variable "image_tag" {
  type        = string
  description = "Container image tag"
  default     = "v2.14.0"
}

variable "replicas" {
  type        = number
  description = "Number of replicas"
  default     = 1
}

variable "cpu_request" {
  type        = string
  description = "CPU request"
  default     = "100m"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit"
  default     = "200m"
}

variable "memory_request" {
  type        = string
  description = "Memory request"
  default     = "150Mi"
}

variable "memory_limit" {
  type        = string
  description = "Memory limit"
  default     = "250Mi"
}