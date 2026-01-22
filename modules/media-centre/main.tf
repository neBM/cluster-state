resource "nomad_job" "media_centre" {
  depends_on = [
    nomad_csi_volume.glusterfs_jellyfin_config,
    nomad_csi_volume.glusterfs_plex_config,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_jellyfin_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_jellyfin_config"
  volume_id = "glusterfs_jellyfin_config"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_plex_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_plex_config"
  volume_id = "glusterfs_plex_config"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}
