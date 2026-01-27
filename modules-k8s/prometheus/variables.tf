variable "app_name" {
  type        = string
  description = "Application name"
  default     = "prometheus"
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
  default     = "prometheus"
}

variable "image_tag" {
  type        = string
  description = "Container image tag"
  default     = "v2.54.1"
}

variable "replicas" {
  type        = number
  description = "Number of replicas"
  default     = 1
}

variable "storage_size" {
  type        = string
  description = "Storage size for Prometheus data"
  default     = "10Gi"
}

variable "storage_class" {
  type        = string
  description = "Storage class for persistent volume"
  default     = "local-path"
}

variable "cpu_request" {
  type        = string
  description = "CPU request"
  default     = "200m"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit"
  default     = "1000m"
}

variable "memory_request" {
  type        = string
  description = "Memory request"
  default     = "512Mi"
}

variable "memory_limit" {
  type        = string
  description = "Memory limit"
  default     = "1Gi"
}

variable "retention_days" {
  type        = number
  description = "Data retention in days"
  default     = 30
}

variable "scrape_interval" {
  type        = string
  description = "Default scrape interval"
  default     = "15s"
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
  default     = "prometheus.brmartin.co.uk"
}

variable "node_affinity_hostname" {
  type        = string
  description = "Preferred node hostname for scheduling"
  default     = "hestia"
}