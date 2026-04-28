variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Public GlitchTip hostname"
  type        = string
  default     = "glitchtip.brmartin.co.uk"
}

variable "image_tag" {
  description = "GlitchTip container image tag"
  type        = string
  # renovate: datasource=docker depName=glitchtip/glitchtip
  default     = "6.1.5"
}
