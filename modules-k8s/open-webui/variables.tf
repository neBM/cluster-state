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
  default = "v0.8.1"
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

# External PostgreSQL on martinibar (192.168.1.10:5433)
# DATABASE_URL is stored in open-webui-secrets
