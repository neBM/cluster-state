variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "PlexTraktSync Docker image"
  type        = string
  default     = "ghcr.io/taxel/plextraktsync:0.34.20"
}

variable "config_path" {
  description = "Host path for PlexTraktSync config"
  type        = string
  default     = "/mnt/docker/downloads/config/plextraktsync"
}
