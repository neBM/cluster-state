resource "nomad_job" "appflowy" {
  depends_on = [
    nomad_csi_volume.glusterfs_appflowy_postgres,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_appflowy_postgres" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_appflowy_postgres"
  volume_id = "glusterfs_appflowy_postgres"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }
}
