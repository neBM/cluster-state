variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "plex_image" {
  description = "Plex Docker image name"
  type        = string
  default     = "plexinc/pms-docker"
}

variable "plex_tag" {
  description = "Plex Docker image tag"
  type        = string
  # renovate: datasource=docker depName=plexinc/pms-docker
  default = "latest"
}

variable "jellyfin_image" {
  description = "Jellyfin Docker image name"
  type        = string
  default     = "ghcr.io/jellyfin/jellyfin"
}

variable "jellyfin_tag" {
  description = "Jellyfin Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/jellyfin/jellyfin
  default = "10.11.6"
}

variable "tautulli_image" {
  description = "Tautulli Docker image name"
  type        = string
  default     = "ghcr.io/tautulli/tautulli"
}

variable "tautulli_tag" {
  description = "Tautulli Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/tautulli/tautulli
  default = "v2.16.1"
}

variable "tautulli_config_path" {
  description = "Host path for Tautulli config"
  type        = string
  default     = "/mnt/docker/downloads/config/tautulli"
}

# Busybox for utility jobs (litestream cleanup)
variable "busybox_image" {
  description = "Busybox Docker image name"
  type        = string
  default     = "busybox"
}

variable "busybox_tag" {
  description = "Busybox Docker image tag"
  type        = string
  # renovate: datasource=docker depName=busybox
  default = "1.37"
}
