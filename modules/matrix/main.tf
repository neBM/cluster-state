locals {
  # Read job specification
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

# Matrix CSI Volumes
resource "nomad_csi_volume" "matrix_synapse_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  volume_id = "glusterfs_matrix_synapse_data"
  name      = "glusterfs_matrix_synapse_data"
  plugin_id = "glusterfs"

  capacity_min = "1GiB"
  capacity_max = "5GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "matrix_media_store" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  volume_id = "glusterfs_matrix_media_store"
  name      = "glusterfs_matrix_media_store"
  plugin_id = "glusterfs"

  capacity_min = "10GiB"
  capacity_max = "50GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "matrix_whatsapp_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  volume_id = "glusterfs_matrix_whatsapp_data"
  name      = "glusterfs_matrix_whatsapp_data"
  plugin_id = "glusterfs"

  capacity_min = "1GiB"
  capacity_max = "5GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_csi_volume" "matrix_config" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  volume_id = "glusterfs_matrix_config"
  name      = "glusterfs_matrix_config"
  plugin_id = "glusterfs"

  capacity_min = "100MiB"
  capacity_max = "1GiB"

  capability {
    access_mode     = "multi-node-reader-only"
    attachment_mode = "file-system"
  }
}

# Matrix Job
resource "nomad_job" "matrix" {
  jobspec = local.jobspec
  depends_on = [
    nomad_csi_volume.matrix_synapse_data,
    nomad_csi_volume.matrix_media_store,
    nomad_csi_volume.matrix_whatsapp_data,
    nomad_csi_volume.matrix_config
  ]
}