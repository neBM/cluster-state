resource "nomad_job" "ollama" {
  depends_on = [
    nomad_csi_volume_registration.nfs_volume_ollama_data,
    nomad_csi_volume_registration.nfs_volume_searxng_config,
    nomad_csi_volume_registration.nfs_volume_firecrawl_data,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "nfs" {
  plugin_id        = "nfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume_registration" "nfs_volume_ollama_data" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "martinibar_prod_ollama_data"
  volume_id   = "martinibar_prod_ollama_data"
  external_id = "martinibar_prod_ollama_data"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/ollama/data",
  }
}

resource "nomad_csi_volume_registration" "nfs_volume_searxng_config" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "martinibar_prod_searxng_config"
  volume_id   = "martinibar_prod_searxng_config"
  external_id = "martinibar_prod_searxng_config"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/searxng/config",
  }
}

resource "nomad_csi_volume_registration" "nfs_volume_firecrawl_data" {
  depends_on = [data.nomad_plugin.nfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id   = "nfs"
  name        = "martinibar_prod_firecrawl_postgres_data"
  volume_id   = "martinibar_prod_firecrawl_postgres_data"
  external_id = "martinibar_prod_firecrawl_postgres_data"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }

  context = {
    "server" = "martinibar.lan",
    "share"  = "/volume1/csi/firecrawl/postgres-data",
  }
}
