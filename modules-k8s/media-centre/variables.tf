variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "plex_image" {
  description = "Plex Docker image"
  type        = string
  default     = "plexinc/pms-docker:latest"
}

variable "jellyfin_image" {
  description = "Jellyfin Docker image"
  type        = string
  default     = "ghcr.io/jellyfin/jellyfin:10.10.6"
}

variable "tautulli_image" {
  description = "Tautulli Docker image"
  type        = string
  default     = "ghcr.io/tautulli/tautulli:v2.15.1"
}

variable "plex_config_path" {
  description = "Host path for Plex config"
  type        = string
  default     = "/storage/v/glusterfs_plex_config"
}

variable "jellyfin_config_path" {
  description = "Host path for Jellyfin config"
  type        = string
  default     = "/storage/v/glusterfs_jellyfin_config"
}

variable "tautulli_config_path" {
  description = "Host path for Tautulli config"
  type        = string
  default     = "/mnt/docker/downloads/config/tautulli"
}
