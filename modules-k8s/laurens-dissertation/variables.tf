variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image" {
  description = "Container image for the dissertation service"
  type        = string
  default     = "registry.brmartin.co.uk/ben/laurens-dissertation:latest"
}

variable "domain" {
  description = "External domain for the dashboard"
  type        = string
  default     = "dissertation.sis.brmartin.co.uk"
}

variable "data_storage_size" {
  description = "PVC size for the SQLite database"
  type        = string
  default     = "1Gi"
}

variable "archive_storage_size" {
  description = "PVC size for raw scraped HTML/JSON archive files"
  type        = string
  default     = "10Gi"
}

variable "data_storage_class" {
  description = "Storage class for the SQLite data PVC — must be local disk (not NFS) to avoid WAL locking issues"
  type        = string
  default     = "local-path-retain"
}

variable "archive_storage_class" {
  description = "Storage class for the archive PVC — GlusterFS is fine for flat file storage"
  type        = string
  default     = "glusterfs-nfs"
}
