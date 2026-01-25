variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Public hostname for AppFlowy"
  type        = string
  default     = "docs.brmartin.co.uk"
}

# =============================================================================
# Container Images
# =============================================================================

variable "gotrue_image" {
  description = "Docker image name for gotrue"
  type        = string
  default     = "appflowyinc/gotrue"
}

variable "gotrue_tag" {
  description = "Docker image tag for gotrue"
  type        = string
  # renovate: datasource=docker depName=appflowyinc/gotrue
  default = "latest"
}

variable "cloud_image" {
  description = "Docker image name for AppFlowy cloud"
  type        = string
  default     = "appflowyinc/appflowy_cloud"
}

variable "cloud_tag" {
  description = "Docker image tag for AppFlowy cloud"
  type        = string
  # renovate: datasource=docker depName=appflowyinc/appflowy_cloud
  default = "latest"
}

variable "worker_image" {
  description = "Docker image name for AppFlowy worker"
  type        = string
  default     = "appflowyinc/appflowy_worker"
}

variable "worker_tag" {
  description = "Docker image tag for AppFlowy worker"
  type        = string
  # renovate: datasource=docker depName=appflowyinc/appflowy_worker
  default = "latest"
}

variable "web_image" {
  description = "Docker image name for AppFlowy web"
  type        = string
  default     = "appflowyinc/appflowy_web"
}

variable "web_tag" {
  description = "Docker image tag for AppFlowy web"
  type        = string
  # renovate: datasource=docker depName=appflowyinc/appflowy_web
  default = "latest"
}

variable "postgres_image" {
  description = "Docker image name for PostgreSQL with pgvector"
  type        = string
  default     = "pgvector/pgvector"
}

variable "postgres_tag" {
  description = "Docker image tag for PostgreSQL with pgvector"
  type        = string
  # renovate: datasource=docker depName=pgvector/pgvector
  default = "pg16"
}

variable "redis_image" {
  description = "Docker image name for Redis"
  type        = string
  default     = "redis"
}

variable "redis_tag" {
  description = "Docker image tag for Redis"
  type        = string
  # renovate: datasource=docker depName=redis
  default = "latest"
}

variable "postgres_data_path" {
  description = "Host path for PostgreSQL data (GlusterFS mount)"
  type        = string
  default     = "/storage/v/glusterfs_appflowy_postgres"
}

variable "minio_endpoint" {
  description = "MinIO S3 endpoint URL"
  type        = string
  default     = "http://minio-api.default.svc.cluster.local:9000"
}

variable "minio_bucket" {
  description = "MinIO bucket name for AppFlowy"
  type        = string
  default     = "appflowy"
}

variable "minio_access_key" {
  description = "MinIO access key (S3 username)"
  type        = string
  default     = "appflowy"
}

variable "keycloak_url" {
  description = "Keycloak realm URL for OIDC"
  type        = string
  default     = "https://sso.brmartin.co.uk/realms/prod"
}

variable "keycloak_client_id" {
  description = "Keycloak client ID for AppFlowy"
  type        = string
  default     = "appflowy"
}

variable "smtp_host" {
  description = "SMTP server host"
  type        = string
  default     = "mail.brmartin.co.uk"
}

variable "smtp_port" {
  description = "SMTP server port"
  type        = string
  default     = "465"
}
