resource "nomad_job" "ollama" {
  depends_on = [
    nomad_csi_volume.glusterfs_ollama_data,
    nomad_csi_volume.glusterfs_searxng_config,
    nomad_csi_volume.glusterfs_ollama_postgres,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_ollama_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_ollama_data"
  volume_id = "glusterfs_ollama_data"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_searxng_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_searxng_config"
  volume_id = "glusterfs_searxng_config"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "glusterfs_ollama_postgres" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_ollama_postgres"
  volume_id = "glusterfs_ollama_postgres"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }
}
