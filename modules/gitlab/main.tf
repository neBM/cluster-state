data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_gitlab_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_gitlab_config"
  volume_id    = "glusterfs_gitlab_config"
  capacity_min = "1GiB"
  capacity_max = "10GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_gitlab_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_gitlab_data"
  volume_id    = "glusterfs_gitlab_data"
  capacity_min = "10GiB"
  capacity_max = "100GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_job" "gitlab" {
  depends_on = [
    nomad_csi_volume.glusterfs_gitlab_config,
    nomad_csi_volume.glusterfs_gitlab_data
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
