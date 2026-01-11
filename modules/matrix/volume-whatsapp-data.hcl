type         = "csi"
id           = "glusterfs_matrix_whatsapp_data"
name         = "glusterfs_matrix_whatsapp_data"
plugin_id    = "org.gluster.glusterfs"
capacity_min = "1GiB"
capacity_max = "5GiB"

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
  share   = "glusterfs_matrix_whatsapp_data"
  network = var.storage_network
}