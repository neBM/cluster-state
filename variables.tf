variable "nomad_address" {
  description = "Address of the Nomad server"
  type        = string
  default     = "http://hestia.lan:4646"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "nfs_server" {
  description = "NFS server address for shared storage"
  type        = string
  default     = "martinibar.lan"
}

variable "timezone" {
  description = "Default timezone for containers"
  type        = string
  default     = "Europe/London"
}

variable "default_cpu" {
  description = "Default CPU allocation in MHz"
  type        = number
  default     = 100
}

variable "default_memory" {
  description = "Default memory allocation in MB"
  type        = number
  default     = 256
}

variable "default_memory_max" {
  description = "Default maximum memory allocation in MB"
  type        = number
  default     = 512
}

variable "postgres_host" {
  description = "PostgreSQL server host"
  type        = string
  default     = "martinibar.lan"
}

variable "postgres_port" {
  description = "PostgreSQL server port"
  type        = string
  default     = "5433"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    managed_by = "terraform"
    project    = "homelab-cluster"
  }
}
