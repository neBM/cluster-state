variable "namespace" {
  description = "Namespace to deploy Goldilocks into"
  type        = string
  default     = "kube-system"
}

variable "image" {
  description = "Goldilocks container image"
  type        = string
  default     = "us-docker.pkg.dev/fairwinds-ops/oss/goldilocks:v4.13.0"
}

variable "enabled_namespaces" {
  description = "List of namespaces to enable Goldilocks VPA creation"
  type        = list(string)
  default     = ["default"]
}

variable "default_vpa_mode" {
  description = "Default VPA update mode for created VPAs (Off, Initial, Auto)"
  type        = string
  default     = "Off"

  validation {
    condition     = contains(["Off", "Initial", "Auto"], var.default_vpa_mode)
    error_message = "VPA mode must be one of: Off, Initial, Auto"
  }
}

variable "enable_dashboard" {
  description = "Whether to deploy the Goldilocks dashboard"
  type        = bool
  default     = true
}

variable "dashboard_host" {
  description = "Hostname for the dashboard IngressRoute (empty to disable)"
  type        = string
  default     = ""
}

variable "dashboard_middlewares" {
  description = "Traefik middlewares to apply to dashboard IngressRoute"
  type = list(object({
    name      = string
    namespace = string
  }))
  default = []
}

variable "tls_secret_name" {
  description = "TLS secret name for IngressRoute"
  type        = string
  default     = "wildcard-brmartin-tls"
}
