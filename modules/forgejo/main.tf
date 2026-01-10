resource "nomad_job" "forgejo" {
  depends_on = [
    nomad_csi_volume.glusterfs_forgejo_gitea,
    nomad_csi_volume.glusterfs_forgejo_git,
    nomad_csi_volume.glusterfs_forgejo_runner_data,
    nomad_csi_volume.glusterfs_forgejo_actions_cache,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_forgejo_gitea" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_forgejo_gitea"
  volume_id    = "glusterfs_forgejo_gitea"
  capacity_min = "1GiB"
  capacity_max = "100GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_forgejo_git" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_forgejo_git"
  volume_id    = "glusterfs_forgejo_git"
  capacity_min = "1GiB"
  capacity_max = "100GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_forgejo_runner_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_forgejo_runner_data"
  volume_id    = "glusterfs_forgejo_runner_data"
  capacity_min = "1GiB"
  capacity_max = "100GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_forgejo_actions_cache" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id    = "glusterfs"
  name         = "glusterfs_forgejo_actions_cache"
  volume_id    = "glusterfs_forgejo_actions_cache"
  capacity_min = "1GiB"
  capacity_max = "100GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}
