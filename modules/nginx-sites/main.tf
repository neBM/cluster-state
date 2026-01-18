resource "nomad_job" "nginx_sites" {
  depends_on = [
    nomad_csi_volume.glusterfs_nginx_sites_code,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_nginx_sites_code" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_nginx_sites_code"
  volume_id    = "glusterfs_nginx_sites_code"
  capacity_min = "100MiB"
  capacity_max = "1GiB"

  capability {
    access_mode     = "multi-node-reader-only"
    attachment_mode = "file-system"
  }
}
