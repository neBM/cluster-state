variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "SearXNG container image tag"
  type        = string
  # renovate: datasource=docker depName=docker.io/searxng/searxng
  default = "2025.11.1-0245327fc"
}

variable "hostname" {
  description = "External hostname for SearXNG"
  type        = string
  default     = "searx.brmartin.co.uk"
}

variable "valkey_url" {
  description = "Valkey (Redis) URL for caching"
  type        = string
  default     = "valkey://ollama-valkey.service.consul/1"
}
