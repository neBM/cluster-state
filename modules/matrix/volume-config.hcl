type         = "csi"
id           = "glusterfs_matrix_config"
name         = "glusterfs_matrix_config"
plugin_id    = "org.gluster.glusterfs"
capacity_min = "100MiB"
capacity_max = "1GiB"

capability {
  access_mode     = "multi-node-reader-only"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = []
}

parameters {
  server  = var.storage_server
  share   = "glusterfs_matrix_config"
  network = var.storage_network
}