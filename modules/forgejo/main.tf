data "nomad_plugin" "martinibar" {
  plugin_id        = "martinibar"
  wait_for_healthy = true
}

resource "nomad_job" "forgejo" {
  depends_on = [
    nomad_csi_volume_registration.gitea,
    nomad_csi_volume_registration.git,
    nomad_csi_volume_registration.runner_data,
    nomad_csi_volume_registration.actions_cache,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

resource "nomad_csi_volume_registration" "gitea" {
  depends_on = [data.nomad_plugin.martinibar]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "martinibar"
  name        = "martinibar_prod_forgejo_gitea"
  volume_id   = "martinibar_prod_forgejo_gitea"
  external_id = "martinibar_prod_forgejo_gitea"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "192.168.1.10",
    "share"  = "/volume1/csi/forgejo/gitea",
  }
}

resource "nomad_csi_volume_registration" "git" {
  depends_on = [data.nomad_plugin.martinibar]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "martinibar"
  name        = "martinibar_prod_forgejo_git"
  volume_id   = "martinibar_prod_forgejo_git"
  external_id = "martinibar_prod_forgejo_git"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "192.168.1.10",
    "share"  = "/volume1/csi/forgejo/git",
  }
}

resource "nomad_csi_volume_registration" "runner_data" {
  depends_on = [data.nomad_plugin.martinibar]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "martinibar"
  name        = "martinibar_prod_forgejo-runner_data"
  volume_id   = "martinibar_prod_forgejo-runner_data"
  external_id = "martinibar_prod_forgejo-runner_data"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "192.168.1.10",
    "share"  = "/volume1/csi/forgejo-runner/data",
  }
}

resource "nomad_csi_volume_registration" "actions_cache" {
  depends_on = [data.nomad_plugin.martinibar]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "martinibar"
  name        = "martinibar_prod_forgejo_actions_cache"
  volume_id   = "martinibar_prod_forgejo_actions_cache"
  external_id = "martinibar_prod_forgejo_actions_cache"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "192.168.1.10",
    "share"  = "/volume1/csi/forgejo/actions-cache",
  }
}
