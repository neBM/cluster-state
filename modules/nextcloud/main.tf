resource "nomad_job" "nextcloud" {
  depends_on = [
    nomad_csi_volume.nextcloud_config,
    nomad_csi_volume.nextcloud_custom_apps,
    nomad_csi_volume.nextcloud_data,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

# GlusterFS volume for Nextcloud config (config.php, etc.)
resource "nomad_csi_volume" "nextcloud_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  volume_id    = "glusterfs_nextcloud_config"
  name         = "glusterfs_nextcloud_config"
  capacity_min = "100MiB"
  capacity_max = "1GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

# GlusterFS volume for Nextcloud custom apps
resource "nomad_csi_volume" "nextcloud_custom_apps" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  volume_id    = "glusterfs_nextcloud_custom_apps"
  name         = "glusterfs_nextcloud_custom_apps"
  capacity_min = "500MiB"
  capacity_max = "5GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

# GlusterFS volume for Nextcloud user data (files + appdata cache)
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

