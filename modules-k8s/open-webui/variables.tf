variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Hostname for Open WebUI"
  type        = string
  default     = "chat.brmartin.co.uk"
}

variable "image" {
  description = "Open WebUI Docker image name"
  type        = string
  default     = "ghcr.io/open-webui/open-webui"
}

variable "image_tag" {
  description = "Open WebUI Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/open-webui/open-webui
  default = "0.7.2"
}

variable "valkey_image" {
  description = "Valkey Docker image name"
  type        = string
  default     = "valkey/valkey"
}

variable "valkey_tag" {
  description = "Valkey Docker image tag"
  type        = string
  # renovate: datasource=docker depName=valkey/valkey
  default = "9.0.0-alpine3.22"
}

variable "postgres_image" {
  description = "pgvector PostgreSQL Docker image name"
  type        = string
  default     = "pgvector/pgvector"
}

variable "postgres_tag" {
  description = "pgvector PostgreSQL Docker image tag"
  type        = string
  # renovate: datasource=docker depName=pgvector/pgvector
  default = "pg18"
}

variable "data_path" {
  description = "Host path for Open WebUI data"
  type        = string
  default     = "/storage/v/glusterfs_ollama_data"
}

variable "postgres_path" {
  description = "Host path for PostgreSQL data"
  type        = string
  default     = "/storage/v/glusterfs_ollama_postgres"
}
