variable "app_name" {
  description = "Application name"
  type        = string
  default     = "headlamp"
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "kube-system"
}

variable "image_registry" {
  description = "Container image registry"
  type        = string
  default     = "ghcr.io"
}

variable "image_name" {
  description = "Container image name"
  type        = string
  default     = "headlamp-k8s/headlamp"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/headlamp-k8s/headlamp
  default = "v0.40.1"
}

variable "replicas" {
  description = "Number of replicas"
  type        = number
  default     = 1
}

variable "cpu_request" {
  description = "CPU request"
  type        = string
  default     = "50m"
}

variable "cpu_limit" {
  description = "CPU limit"
  type        = string
  default     = "250m"
}

variable "memory_request" {
  description = "Memory request"
  type        = string
  default     = "128Mi"
}

variable "memory_limit" {
  description = "Memory limit"
  type        = string
  default     = "256Mi"
}

variable "ingress_hostname" {
  description = "Hostname for Traefik IngressRoute"
  type        = string
  default     = "headlamp.brmartin.co.uk"
}

variable "tls_secret_name" {
  description = "TLS secret name for ingress"
  type        = string
  default     = "wildcard-brmartin-tls"
}

variable "traefik_middlewares" {
  description = "List of Traefik middleware names to apply"
  type        = list(string)
  default     = []
}

# OIDC Configuration (Keycloak)
variable "oidc_issuer_url" {
  description = "OIDC issuer URL (Keycloak realm)"
  type        = string
  default     = "https://sso.brmartin.co.uk/realms/prod"
}

variable "oidc_client_id" {
  description = "OIDC client ID"
  type        = string
  default     = "headlamp"
}

variable "oidc_scopes" {
  description = "OIDC scopes to request"
  type        = string
  default     = "openid,profile,email"
}

