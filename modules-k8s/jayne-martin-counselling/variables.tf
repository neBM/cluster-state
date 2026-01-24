variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "latest"
}

variable "vpa_mode" {
  description = "VPA update mode: Auto, Off, or Initial"
  type        = string
  default     = "Off" # Recommendations only
}
