variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Vaultwarden image tag"
  type        = string
  default     = "latest"
}

variable "hostname" {
  description = "Hostname for vaultwarden"
  type        = string
  default     = "bw.brmartin.co.uk"
}
