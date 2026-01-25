variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Ollama image tag"
  type        = string
  # renovate: datasource=docker depName=ollama/ollama
  default = "0.14.3"
}
