variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Keycloak container image tag"
  type        = string
  default     = "26.5.1"
}

variable "hostname" {
  description = "Hostname for Keycloak SSO"
  type        = string
  default     = "sso.brmartin.co.uk"
}

variable "db_host" {
  description = "PostgreSQL database host"
  type        = string
  default     = "192.168.1.10"
}

variable "db_port" {
  description = "PostgreSQL database port"
  type        = string
  default     = "5433"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "PostgreSQL database username"
  type        = string
  default     = "keycloak"
}
