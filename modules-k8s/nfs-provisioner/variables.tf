variable "namespace" {
  description = "Kubernetes namespace for the provisioner"
  type        = string
  default     = "default"
}

variable "nfs_server" {
  description = "NFS server address"
  type        = string
  default     = "127.0.0.1"
}

variable "nfs_path" {
  description = "NFS export path"
  type        = string
  default     = "/storage/v"
}

variable "storage_class_name" {
  description = "Name of the StorageClass to create"
  type        = string
  default     = "glusterfs-nfs"
}

variable "reclaim_policy" {
  description = "What happens to PV when PVC is deleted (Retain or Delete)"
  type        = string
  default     = "Retain"
}

variable "path_pattern" {
  description = "Directory naming pattern for provisioned volumes"
  type        = string
  default     = "glusterfs_$${.PVC.annotations.volume-name}"
}

variable "provisioner_image" {
  description = "Container image name for the NFS provisioner"
  type        = string
  default     = "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner"
}

variable "provisioner_tag" {
  description = "Container image tag for the NFS provisioner"
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/sig-storage/nfs-subdir-external-provisioner
  default = "v4.0.2"
}
