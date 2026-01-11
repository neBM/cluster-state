type         = "csi"
id           = "glusterfs_matrix_media_store"
name         = "glusterfs_matrix_media_store"
plugin_id    = "org.gluster.glusterfs"
capacity_min = "10GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = []
}

parameters {
  server  = var.storage_server
  share   = "glusterfs_matrix_media_store"
  network = var.storage_network
}