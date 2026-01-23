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

# Image
variable "gitlab_image" {
  description = "GitLab CE Docker image"
  type        = string
  default     = "gitlab/gitlab-ce:18.8.2-ce.0"
}

# Storage paths (GlusterFS NFS mounts on Hestia)
variable "config_path" {
  description = "Path to GitLab config volume"
  type        = string
  default     = "/storage/v/glusterfs_gitlab_config"
}

variable "data_path" {
  description = "Path to GitLab data volume"
  type        = string
  default     = "/storage/v/glusterfs_gitlab_data"
}

# Database configuration
variable "db_host" {
  description = "PostgreSQL host"
  type        = string
  default     = "192.168.1.10"
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = string
  default     = "5433"
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

# SSH configuration (advertised port in clone URLs)
variable "ssh_port" {
  description = "Git SSH port (advertised to users for clone URLs)"
  type        = number
  default     = 2222
}

# Resources
variable "memory_request" {
  description = "Memory request"
  type        = string
  default     = "3Gi"
}

variable "memory_limit" {
  description = "Memory limit"
  type        = string
  default     = "6Gi"
}

variable "cpu_request" {
  description = "CPU request"
  type        = string
  default     = "1000m"
}
