resource "nomad_job" "vaultwarden" {
  depends_on = [
    nomad_csi_volume.glusterfs_vaultwarden_data,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_vaultwarden_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_vaultwarden_data"
  volume_id    = "glusterfs_vaultwarden_data"
  capacity_min = "100MiB"
  capacity_max = "10GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}
