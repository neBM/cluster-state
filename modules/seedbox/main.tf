resource "nomad_job" "seedbox" {
  depends_on = [
    nomad_csi_volume_registration.nfs_volume_media,
    nomad_csi_volume_registration.nfs_volume_qbittorrent_config,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "nfs" {
  plugin_id        = "nfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume_registration" "nfs_volume_media" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "media"
  volume_id   = "media"
  external_id = "media"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/media",
  }
}

resource "nomad_csi_volume_registration" "nfs_volume_qbittorrent_config" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "qbittorrent_config"
  volume_id   = "qbittorrent_config"
  external_id = "qbittorrent_config"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/qbittorrent_config",
  }
}
