variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Container image tag for overseerr"
  type        = string
  default     = "latest"
}

variable "litestream_image_tag" {
  description = "Container image tag for litestream"
  type        = string
  default     = "0.5"
}

variable "vpa_mode" {
  description = "VPA update mode: Auto, Off, or Initial"
  type        = string
  default     = "Auto" # Full VPA for stateful PoC
}

variable "storage_size" {
  description = "Size of the persistent volume for data"
  type        = string
  default     = "1Gi"
}

variable "minio_endpoint" {
  description = "MinIO endpoint for litestream backups"
  type        = string
  default     = "http://minio.default.svc.cluster.local:9000"
}

variable "litestream_bucket" {
  description = "S3 bucket name for litestream backups"
  type        = string
  default     = "overseerr-k8s-litestream"
}
