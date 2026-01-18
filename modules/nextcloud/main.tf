resource "nomad_job" "nextcloud" {
  depends_on = [
    nomad_csi_volume.nextcloud_app,
    nomad_csi_volume.nextcloud_data,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

# GlusterFS volume for Nextcloud app files (themes, custom_apps, config)
resource "nomad_csi_volume" "nextcloud_app" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  volume_id    = "glusterfs_nextcloud_app"
  name         = "glusterfs_nextcloud_app"
  capacity_min = "2GiB"
  capacity_max = "5GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

# GlusterFS volume for Nextcloud user data
resource "nomad_csi_volume" "nextcloud_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  volume_id    = "glusterfs_nextcloud_data"
  name         = "glusterfs_nextcloud_data"
  capacity_min = "100MiB"
  capacity_max = "100GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}
