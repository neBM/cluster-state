variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Hostname for overseerr"
  type        = string
  default     = "overseerr.brmartin.co.uk"
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
  default     = "Off" # Recommendations only for production
}

variable "s3_endpoint" {
  description = "S3-compatible endpoint for litestream backups"
  type        = string
  default     = "http://seaweedfs-s3.default.svc.cluster.local:8333"
}

variable "litestream_bucket" {
  description = "S3 bucket name for litestream backups"
  type        = string
  default     = "overseerr-litestream"
}
