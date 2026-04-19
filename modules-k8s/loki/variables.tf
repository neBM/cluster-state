variable "app_name" {
  type        = string
  description = "Application name"
  default     = "loki"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_tag" {
  type        = string
  description = "Loki container image tag"
  default     = "3.4.1"
}

variable "s3_endpoint" {
  type        = string
  description = "S3-compatible endpoint (host:port, no scheme)"
  default     = "seaweedfs-s3.default.svc.cluster.local:8333"
}

variable "s3_bucket" {
  type        = string
  description = "S3 bucket name for Loki chunks and index"
  default     = "loki"
}

variable "s3_secret_name" {
  type        = string
  description = "Kubernetes Secret name containing MINIO_ACCESS_KEY and MINIO_SECRET_KEY"
  default     = "loki-s3"
}

variable "retention_period" {
  type        = string
  description = "Log retention period (e.g. 720h = 30 days)"
  default     = "720h"
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

variable "storage_class_name" {
  type        = string
  description = "StorageClass for the Loki PVC. Must be a node-local class — Grafana's docs explicitly call out network/FUSE filesystems as unsuitable for the WAL fsync path."
  default     = "local-path-retain"
}

variable "storage_size" {
  type        = string
  description = "Size of the Loki data PVC (WAL + index cache + compactor workdir). Chunks live in S3; this is just local working state."
  default     = "20Gi"
}

variable "node_selector" {
  type        = map(string)
  description = "Node selector for the Loki pod. Required because the local-path provisioner creates the PV directory on whichever node the pod first schedules to — pin the pod to make that choice deterministic."
  default = {
    "kubernetes.io/hostname" = "hestia"
  }
}
