resource "nomad_job" "volts-app" {
  depends_on = [
    nomad_csi_volume_registration.nfs_volume,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "nfs" {
  plugin_id        = "nfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume_registration" "nfs_volume" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "martinibar_prod_volts-app_data"
  volume_id   = "martinibar_prod_volts-app_data"
  external_id = "martinibar_prod_volts-app_data"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/volts-app/data",
  }
}
