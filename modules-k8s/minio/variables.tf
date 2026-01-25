variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "MinIO container image tag"
  type        = string
  # renovate: datasource=docker depName=quay.io/minio/minio
  default = "latest"
}

variable "console_hostname" {
  description = "Hostname for MinIO console (web UI)"
  type        = string
  default     = "minio.brmartin.co.uk"
}

variable "data_path" {
  description = "Host path to MinIO data directory (GlusterFS mount)"
  type        = string
  default     = "/storage/v/glusterfs_minio_data"
}
