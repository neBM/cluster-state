resource "nomad_job" "searxng" {
  depends_on = [
    nomad_csi_volume.glusterfs_searxng_config,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_searxng_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_searxng_config"
  volume_id    = "glusterfs_searxng_config"
  capacity_min = "1GiB"
  capacity_max = "10GiB"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }
}
