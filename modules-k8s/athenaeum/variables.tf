variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "backend_image" {
  description = "Athenaeum backend container image"
  type        = string
  default     = "registry.brmartin.co.uk/ben/athenaeum/backend:d21b365d"
}

variable "frontend_image" {
  description = "Athenaeum frontend container image"
  type        = string
  default     = "registry.brmartin.co.uk/ben/athenaeum/frontend:d21b365d"
}

variable "domain" {
  description = "External domain for Athenaeum"
  type        = string
  default     = "athenaeum.brmartin.co.uk"
}

variable "redis_image" {
  description = "Redis container image"
  type        = string
  default     = "redis:7-alpine"
}
