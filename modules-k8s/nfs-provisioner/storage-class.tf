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

  # vers=4.1: pin to NFSv4.1 to avoid NFSv4.2 negotiation. Ganesha GLUSTER FSAL
  # does not fully support NFSv4.2 operations.
  #
  # nosharecache: force per-mount superblock. Without this, the kernel shares
  # superblocks (and dentry/inode caches) between mounts to the same server+export.
  # After a Ganesha restart, zombie superblocks from lazy-unmounted pods can poison
  # new mounts with stale file handles → EIO.
  #
  # context=...: suppress SELinux xattr lookups (EOPNOTSUPP) on NFS mounts.
  #
  # NOTE: Kernel 6.18+ requires nfsv4 directory_delegations=N (modprobe.d) to
  # prevent EREMOTEIO from Ganesha returning NFS4ERR_OP_ILLEGAL for
  # GET_DIR_DELEGATION. See docs/storage-troubleshooting.md §10.
  mount_options = ["vers=4.1", "nosharecache", "context=system_u:object_r:nfs_t:s0"]
}
