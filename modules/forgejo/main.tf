resource "nomad_job" "forgejo" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "nfs" {
  plugin_id        = "nfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume_registration" "actions_cache" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "martinibar_prod_forgejo_actions_cache"
  volume_id   = "martinibar_prod_forgejo_actions_cache"
  external_id = "martinibar_prod_forgejo_actions_cache"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/forgejo/actions-cache",
  }
}
