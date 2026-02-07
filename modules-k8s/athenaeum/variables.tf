variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "backend_image" {
  description = "Athenaeum backend container image"
  type        = string
  default     = "registry.brmartin.co.uk/ben/athenaeum/backend:597d4569"
}

variable "frontend_image" {
  description = "Athenaeum frontend container image"
  type        = string
  default     = "registry.brmartin.co.uk/ben/athenaeum/frontend:9e84034f"
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

variable "keycloak_url" {
  description = "Keycloak server URL"
  type        = string
  default     = "https://sso.brmartin.co.uk"
}

variable "keycloak_realm" {
  description = "Keycloak realm name"
  type        = string
  default     = "prod"
}

variable "keycloak_client_id" {
  description = "Keycloak client ID for frontend (public client)"
  type        = string
  default     = "athenaeum-ui"
}
