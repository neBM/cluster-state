variable "namespace" {
  description = "Kubernetes namespace for all Iris resources"
  type        = string
  default     = "default"
}

# renovate: datasource=docker
variable "image" {
  description = "Iris unified container image — Go binary with embedded SPA (registry.brmartin.co.uk/ben/iris:<sha>)"
  type        = string
  default     = "registry.brmartin.co.uk/ben/iris:latest"
}

# renovate: datasource=docker
variable "valkey_image" {
  description = "Valkey container image"
  type        = string
  default     = "valkey/valkey:8-alpine"
}

variable "hostname" {
  description = "Public hostname for the Iris web UI"
  type        = string
  default     = "iris.brmartin.co.uk"
}

variable "auth_mode" {
  description = "Authentication backend: 'oidc' uses Keycloak (requires keycloak_issuer_url and keycloak_audience); 'local' uses built-in username/password"
  type        = string
  default     = "oidc"

  validation {
    condition     = contains(["local", "oidc"], var.auth_mode)
    error_message = "auth_mode must be 'local' or 'oidc'."
  }
}

variable "local_auth_session_ttl_seconds" {
  description = "How long a local-auth session token remains valid (seconds). Only used when auth_mode = 'local'."
  type        = number
  default     = 86400
}

variable "keycloak_issuer_url" {
  description = "Keycloak OIDC issuer URL used for JWT validation. Required when auth_mode = 'oidc'."
  type        = string
  default     = "https://sso.brmartin.co.uk/realms/prod"
}

variable "keycloak_audience" {
  description = "Expected JWT audience (Keycloak client ID). Required when auth_mode = 'oidc'."
  type        = string
  default     = "iris-api"
}

variable "oidc_admin_claim" {
  description = "JWT claim name used for OIDC admin role mapping (e.g. 'groups'). Only used when auth_mode = 'oidc'. If empty, all OIDC users receive the Viewer role."
  type        = string
  default     = "groups"
}

variable "oidc_admin_value" {
  description = "Value within the OIDC admin claim that grants the Admin role (e.g. 'iris-admin'). Only used when auth_mode = 'oidc'."
  type        = string
  default     = "iris-admin"
}

variable "oidc_client_id" {
  description = "OIDC client ID for the SPA frontend. Required when auth_mode = 'oidc'. Served via the dynamic /config.js endpoint."
  type        = string
  default     = "iris"
}

variable "oidc_redirect_uri" {
  description = "OIDC redirect URI for the SPA frontend. Required when auth_mode = 'oidc'. Defaults to https://<hostname>/."
  type        = string
  default     = ""
}

variable "oidc_silent_redirect_uri" {
  description = "OIDC silent redirect URI for token renewal. Required when auth_mode = 'oidc'. Defaults to https://<hostname>/silent-renew.html."
  type        = string
  default     = ""
}

variable "media_nfs_server" {
  description = "NFS server hostname or IP that exports the media library"
  type        = string
}

variable "media_nfs_path" {
  description = "NFS export path containing media directories (mounted at /media in the API container)"
  type        = string
}

variable "media_dirs" {
  description = "MEDIA_DIRS env var: comma-separated list of name:path pairs relative to the media NFS mount"
  type        = string
  default     = "Movies:/media/movies,TV:/media/tv"
}
