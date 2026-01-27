variable "app_name" {
  type        = string
  description = "Application name"
  default     = "meshery"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_registry" {
  type        = string
  description = "Container image registry"
  default     = "meshery"
}

variable "image_name" {
  type        = string
  description = "Container image name"
  default     = "meshery"
}

variable "image_tag" {
  type        = string
  description = "Container image tag"
  default     = "stable-v0.8.200"
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
  default     = "500m"
}

variable "memory_request" {
  type        = string
  description = "Memory request"
  default     = "256Mi"
}

variable "memory_limit" {
  type        = string
  description = "Memory limit"
  default     = "1Gi"
}

variable "traefik_middlewares" {
  type        = list(string)
  description = "Traefik middlewares to apply"
  default     = []
}

variable "tls_secret_name" {
  type        = string
  description = "TLS certificate secret name"
  default     = "wildcard-brmartin-tls"
}

variable "ingress_hostname" {
  type        = string
  description = "Ingress hostname"
  default     = "meshery.brmartin.co.uk"
}