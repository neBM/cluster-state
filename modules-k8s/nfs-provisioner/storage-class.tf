# StorageClass for dynamic volume provisioning
# Uses pathPattern to create directories matching glusterfs_<service>_<type> convention
resource "kubernetes_storage_class" "glusterfs_nfs" {
  metadata {
    name = var.storage_class_name
    labels = {
      app        = "nfs-subdir-external-provisioner"
      managed-by = "terraform"
    }
  }

  storage_provisioner = "nfs.io/nfs-subdir-external-provisioner"
  reclaim_policy      = var.reclaim_policy

  # Immediate binding - provision as soon as PVC is created
  volume_binding_mode = "Immediate"

  parameters = {
    # Directory naming pattern - uses PVC annotation for custom naming
    # Example: volume-name: myapp_data -> /storage/v/glusterfs_myapp_data
    pathPattern = var.path_pattern

    # Retain directory on PVC deletion (data safety)
    onDelete = "retain"
  }

  # Allow volume expansion (no-op for NFS, but required for some workflows)
  allow_volume_expansion = false
}
