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

variable "auth_providers" {
  description = "Comma-separated list of active authentication providers. Valid values: 'local', 'oidc', or 'local,oidc'."
  type        = string
  default     = "oidc"

  validation {
    condition     = alltrue([for p in split(",", var.auth_providers) : contains(["local", "oidc"], trimspace(p))])
    error_message = "auth_providers must be a comma-separated list of 'local' and/or 'oidc'."
  }
}

variable "local_auth_session_ttl_seconds" {
  description = "How long a local-auth session token remains valid (seconds). Only used when auth_providers includes 'local'."
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
  description = "OIDC silent redirect URI for token renewal. Only used when auth_providers includes 'oidc'. Defaults to https://<hostname>/silent-renew.html."
  type        = string
  default     = ""
}

variable "oidc_provider_name" {
  description = "Display name for the OIDC provider shown in the login picker UI (e.g. 'Keycloak', 'Google'). Only used when auth_providers includes 'oidc'."
  type        = string
  default     = "SSO"
}

variable "plex_client_id" {
  description = "Stable X-Plex-Client-Identifier UUID for this Iris installation. If empty, a UUID is generated at startup and persisted in the settings table."
  type        = string
  default     = ""
}

variable "db_max_conns" {
  description = "Maximum number of PostgreSQL connections in the pool."
  type        = number
  default     = 10
}

variable "max_concurrent_sessions" {
  description = "Maximum number of active streaming sessions system-wide. 0 means no cap."
  type        = number
  default     = 0
}

variable "transcode_workers" {
  description = "Number of concurrent transcode queue workers."
  type        = number
  default     = 1
}

variable "scanner_parallelism" {
  description = "Number of files the library scanner probes concurrently."
  type        = number
  default     = 4
}

variable "image_cache_max_size" {
  description = "Maximum total size in bytes of the image cache directory. 0 means no eviction."
  type        = number
  default     = 0
}

variable "trusted_proxies" {
  description = "Comma-separated list of proxy IPs/CIDRs whose X-Forwarded-For headers are trusted for client IP extraction."
  type        = string
  default     = "10.42.0.0/16"
}

variable "app_origin" {
  description = "Allowed origin for WebSocket connections. Defaults to https://<hostname>."
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
