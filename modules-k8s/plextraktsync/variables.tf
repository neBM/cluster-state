variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "PlexTraktSync Docker image name"
  type        = string
  default     = "ghcr.io/taxel/plextraktsync"
}

variable "image_tag" {
  description = "PlexTraktSync Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/taxel/plextraktsync
  default = "0.34.20"
}

variable "config_path" {
  description = "Host path for PlexTraktSync config"
  type        = string
  default     = "/mnt/docker/downloads/config/plextraktsync"
}
