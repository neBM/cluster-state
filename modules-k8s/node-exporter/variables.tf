variable "app_name" {
  type        = string
  description = "Application name"
  default     = "node-exporter"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_registry" {
  type        = string
  description = "Container image registry"
  default     = "prom"
}

variable "image_name" {
  type        = string
  description = "Container image name"
  default     = "node-exporter"
}

variable "image_tag" {
  type        = string
  description = "Container image tag"
  default     = "v1.10.2"
}

variable "cpu_request" {
  type        = string
  description = "CPU request"
  default     = "50m"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit"
  default     = "200m"
}

variable "memory_request" {
  type        = string
  description = "Memory request"
  default     = "50Mi"
}

variable "memory_limit" {
  type        = string
  description = "Memory limit"
  default     = "100Mi"
}