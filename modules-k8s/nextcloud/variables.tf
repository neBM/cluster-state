variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Public hostname for Nextcloud"
  type        = string
  default     = "cloud.brmartin.co.uk"
}

variable "collabora_hostname" {
  description = "Public hostname for Collabora"
  type        = string
  default     = "collabora.brmartin.co.uk"
}

variable "nextcloud_image" {
  description = "Docker image name for Nextcloud"
  type        = string
  default     = "nextcloud"
}

variable "nextcloud_tag" {
  description = "Docker image tag for Nextcloud"
  type        = string
  # renovate: datasource=docker depName=nextcloud
  default = "32"
}

variable "collabora_image" {
  description = "Docker image name for Collabora"
  type        = string
  default     = "collabora/code"
}

variable "collabora_tag" {
  description = "Docker image tag for Collabora"
  type        = string
  # renovate: datasource=docker depName=collabora/code
  default = "latest"
}

variable "redis_image" {
  description = "Docker image name for Redis"
  type        = string
  default     = "redis"
}

variable "redis_tag" {
  description = "Docker image tag for Redis"
  type        = string
  # renovate: datasource=docker depName=redis
  default = "8-alpine"
}

variable "config_path" {
  description = "Host path for Nextcloud config (GlusterFS mount)"
  type        = string
  default     = "/storage/v/glusterfs_nextcloud_config"
}

variable "custom_apps_path" {
  description = "Host path for Nextcloud custom apps (GlusterFS mount)"
  type        = string
  default     = "/storage/v/glusterfs_nextcloud_custom_apps"
}

variable "data_path" {
  description = "Host path for Nextcloud data (GlusterFS mount)"
  type        = string
  default     = "/storage/v/glusterfs_nextcloud_data"
}

variable "db_host" {
  description = "PostgreSQL host"
  type        = string
  default     = "192.168.1.10"
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = string
  default     = "5433"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "nextcloud"
}

variable "db_user" {
  description = "PostgreSQL username"
  type        = string
  default     = "nextcloud"
}
