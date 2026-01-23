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
  description = "Open WebUI Docker image"
  type        = string
  default     = "ghcr.io/open-webui/open-webui:0.7.2"
}

variable "valkey_image" {
  description = "Valkey Docker image"
  type        = string
  default     = "valkey/valkey:9.0.0-alpine3.22"
}

variable "postgres_image" {
  description = "pgvector PostgreSQL Docker image"
  type        = string
  default     = "pgvector/pgvector:pg18"
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
