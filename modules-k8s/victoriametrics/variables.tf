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
  default     = "900Mi"
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

# S3 backup configuration (SeaweedFS)
variable "s3_endpoint" {
  type        = string
  description = "S3-compatible API endpoint"
  default     = "http://seaweedfs-s3.default.svc.cluster.local:8333"
}

variable "s3_bucket" {
  type        = string
  description = "S3 bucket for backups"
  default     = "victoriametrics"
}

variable "s3_secret_name" {
  type        = string
  description = "Name of existing K8s secret with MINIO_ACCESS_KEY and MINIO_SECRET_KEY"
  default     = "victoriametrics-s3"
}

variable "backup_interval" {
  type        = string
  description = "Backup interval for vmbackup (e.g., 1h, 30m)"
  default     = "1h"
}

# Storage configuration (local PV)
variable "storage_class_name" {
  type        = string
  description = "StorageClass for the VictoriaMetrics PVC. Should be a node-local class (late-binding) to avoid network-FS fsync latency on the TSDB write path."
  default     = "local-path-retain"
}

variable "storage_size" {
  type        = string
  description = "Size of the VictoriaMetrics data PVC"
  default     = "20Gi"
}

variable "node_selector" {
  type        = map(string)
  description = "Node selector for the VictoriaMetrics pod. Required because the local-path provisioner creates the PV directory on whichever node the pod first schedules to — pin the pod to make that choice deterministic."
  default = {
    "kubernetes.io/hostname" = "hestia"
  }
}

