variable "namespace" {
  description = "Kubernetes namespace for all Iris resources"
  type        = string
  default     = "default"
}

# renovate: datasource=docker
variable "api_image" {
  description = "Iris API container image (registry.brmartin.co.uk/ben/iris/api:<sha>)"
  type        = string
  default     = "registry.brmartin.co.uk/ben/iris/api:latest"
}

# renovate: datasource=docker
variable "web_image" {
  description = "Iris web container image (registry.brmartin.co.uk/ben/iris/web:<sha>)"
  type        = string
  default     = "registry.brmartin.co.uk/ben/iris/web:latest"
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

variable "keycloak_issuer_url" {
  description = "Keycloak OIDC issuer URL used for JWT validation"
  type        = string
  default     = "https://sso.brmartin.co.uk/realms/prod"
}

variable "keycloak_audience" {
  description = "Expected JWT audience (Keycloak client ID)"
  type        = string
  default     = "iris-api"
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
