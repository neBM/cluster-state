data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_overseerr_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_overseerr_config"
  volume_id = "glusterfs_overseerr_config"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_job" "overseerr" {
  depends_on = [nomad_csi_volume.glusterfs_overseerr_config]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
