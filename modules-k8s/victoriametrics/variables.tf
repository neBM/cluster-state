variable "app_name" {
  type        = string
  description = "Application name"
  default     = "victoriametrics"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_tag" {
  type        = string
  description = "VictoriaMetrics image tag"
  default     = "v1.108.1"
}

variable "cpu_request" {
  type        = string
  description = "CPU request"
  default     = "100m"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit"
  default     = "1000m"
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

variable "retention_period" {
  type        = string
  description = "Data retention period (e.g., 30d, 90d, 1y)"
  default     = "30d"
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
  default     = "victoriametrics.brmartin.co.uk"
}

# MinIO backup configuration
variable "minio_endpoint" {
  type        = string
  description = "MinIO API endpoint"
  default     = "http://minio-api.default.svc.cluster.local:9000"
}

variable "minio_bucket" {
  type        = string
  description = "MinIO bucket for backups"
  default     = "victoriametrics"
}

variable "minio_secret_name" {
  type        = string
  description = "Name of existing K8s secret with AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
  default     = "victoriametrics-minio"
}

variable "backup_interval" {
  type        = string
  description = "Backup interval for vmbackup (e.g., 1h, 30m)"
  default     = "1h"
}
