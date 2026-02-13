variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

# Hostnames
variable "gitlab_hostname" {
  description = "Hostname for GitLab web UI"
  type        = string
  default     = "git.brmartin.co.uk"
}

variable "registry_hostname" {
  description = "Hostname for GitLab Container Registry"
  type        = string
  default     = "registry.brmartin.co.uk"
}

# =============================================================================
# CNG Images (Cloud Native GitLab)
# =============================================================================

variable "gitlab_version" {
  description = "GitLab version tag for CNG images"
  type        = string
  # renovate: datasource=docker depName=registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice-ce
  default = "v18.8.4"
}

variable "webservice_image" {
  description = "GitLab Webservice (Rails) image"
  type        = string
  default     = "registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice-ce"
}

variable "workhorse_image" {
  description = "GitLab Workhorse image"
  type        = string
  default     = "registry.gitlab.com/gitlab-org/build/cng/gitlab-workhorse-ce"
}

variable "sidekiq_image" {
  description = "GitLab Sidekiq image"
  type        = string
  default     = "registry.gitlab.com/gitlab-org/build/cng/gitlab-sidekiq-ce"
}

variable "gitaly_image" {
  description = "Gitaly image"
  type        = string
  default     = "registry.gitlab.com/gitlab-org/build/cng/gitaly"
}

variable "registry_image" {
  description = "GitLab Container Registry image"
  type        = string
  default     = "registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry"
}

variable "redis_image" {
  description = "Redis image name"
  type        = string
  default     = "redis"
}

variable "redis_tag" {
  description = "Redis image tag"
  type        = string
  # renovate: datasource=docker depName=redis
  default = "8-alpine"
}

# =============================================================================
# Legacy Storage paths (for migration reference)
# =============================================================================

variable "legacy_config_path" {
  description = "Legacy path to GitLab config volume (for migration)"
  type        = string
  default     = "/storage/v/glusterfs_gitlab_config"
}

variable "legacy_data_path" {
  description = "Legacy path to GitLab data volume (for migration)"
  type        = string
  default     = "/storage/v/glusterfs_gitlab_data"
}

# =============================================================================
# Database configuration
# =============================================================================

variable "db_host" {
  description = "PostgreSQL host"
  type        = string
  default     = "192.168.1.10"
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = number
  default     = 5433
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "gitlabhq_production"
}

variable "db_user" {
  description = "PostgreSQL username"
  type        = string
  default     = "gitlab"
}

# =============================================================================
# SSH configuration
# =============================================================================

variable "ssh_port" {
  description = "Git SSH port (advertised to users for clone URLs)"
  type        = number
  default     = 2222
}

# =============================================================================
# Resources
# =============================================================================

# Webservice (Rails)
variable "webservice_memory_request" {
  description = "Webservice memory request"
  type        = string
  default     = "1.5Gi"
}

variable "webservice_memory_limit" {
  description = "Webservice memory limit"
  type        = string
  default     = "3Gi"
}

variable "webservice_cpu_request" {
  description = "Webservice CPU request"
  type        = string
  default     = "75m"
}

# Workhorse
variable "workhorse_memory_request" {
  description = "Workhorse memory request"
  type        = string
  default     = "64Mi"
}

variable "workhorse_memory_limit" {
  description = "Workhorse memory limit"
  type        = string
  default     = "256Mi"
}

variable "workhorse_cpu_request" {
  description = "Workhorse CPU request"
  type        = string
  default     = "100m"
}

# Sidekiq
variable "sidekiq_memory_request" {
  description = "Sidekiq memory request"
  type        = string
  default     = "1536Mi"
}

variable "sidekiq_memory_limit" {
  description = "Sidekiq memory limit"
  type        = string
  default     = "2Gi"
}

variable "sidekiq_cpu_request" {
  description = "Sidekiq CPU request"
  type        = string
  default     = "150m"
}

# Gitaly
variable "gitaly_memory_request" {
  description = "Gitaly memory request"
  type        = string
  default     = "512Mi"
}

variable "gitaly_memory_limit" {
  description = "Gitaly memory limit"
  type        = string
  default     = "512Mi"
}

variable "gitaly_cpu_request" {
  description = "Gitaly CPU request"
  type        = string
  default     = "50m"
}

# Registry
variable "registry_memory_request" {
  description = "Registry memory request"
  type        = string
  default     = "64Mi"
}

variable "registry_memory_limit" {
  description = "Registry memory limit"
  type        = string
  default     = "256Mi"
}

variable "registry_cpu_request" {
  description = "Registry CPU request"
  type        = string
  default     = "100m"
}

# Redis
variable "redis_memory_request" {
  description = "Redis memory request"
  type        = string
  default     = "64Mi"
}

variable "redis_memory_limit" {
  description = "Redis memory limit"
  type        = string
  default     = "256Mi"
}

variable "redis_cpu_request" {
  description = "Redis CPU request"
  type        = string
  default     = "50m"
}
