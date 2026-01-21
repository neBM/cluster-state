variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "0.9.2"
}

variable "allowed_sources" {
  description = "List of app labels allowed to access echo"
  type        = list(string)
  default     = ["whoami"]
}
