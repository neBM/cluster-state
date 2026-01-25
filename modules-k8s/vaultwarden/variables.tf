variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Vaultwarden image tag"
  type        = string
  # renovate: datasource=docker depName=vaultwarden/server
  default = "latest"
}

variable "hostname" {
  description = "Hostname for vaultwarden"
  type        = string
  default     = "bw.brmartin.co.uk"
}
