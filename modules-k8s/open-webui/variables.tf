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
  default = "v0.9.1"
}

# External PostgreSQL on martinibar (192.168.1.10:5433)
# DATABASE_URL is stored in open-webui-secrets
