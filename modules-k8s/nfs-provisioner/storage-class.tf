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

  # soft: return EIO to the application after retrans failures instead of
  # blocking the kernel NFS thread indefinitely. On localhost NFS-Ganesha, an
  # unresponsive server means the local daemon is already dead — failing fast
  # prevents a single stalled mount from freezing the entire node.
  #
  # softerr: NFSv4-specific complement to soft. With soft alone, NFSv4 enters
  # session recovery on RPC timeout and blocks in D state indefinitely —
  # SIGKILL cannot reach processes in this state. softerr (Linux 5.10+) bypasses
  # session recovery and returns EIO immediately when timeo*retrans expires,
  # making soft actually effective for NFSv4 mounts.
  #
  # timeo=30: 3-second major timeout per attempt (timeo is in tenths of a second).
  # retrans=3: retry up to 3 times before returning EIO (~9s total).
  #
  # context=...: suppress SELinux xattr lookups (EOPNOTSUPP) on NFS mounts.
  # NFS does not support security.selinux xattrs, so the kernel logs a warning
  # for every inode access. A fixed context label prevents per-inode getxattr calls.
  mount_options = ["soft", "softerr", "timeo=30", "retrans=3", "context=system_u:object_r:nfs_t:s0"]
}
