resource "nomad_job" "minio" {
  depends_on = [
    nomad_csi_volume.glusterfs_minio_data,
  ]

  jobspec = file("${path.module}/jobspec.nomad.hcl")
}

data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

resource "nomad_csi_volume" "glusterfs_minio_data" {
  depends_on = [data.nomad_plugin.glusterfs]

  lifecycle {
    prevent_destroy = true
  }

  plugin_id = "glusterfs"
  name      = "glusterfs_minio_data"
  volume_id = "glusterfs_minio_data"

  capability {
    access_mode     = "multi-node-single-writer"
    attachment_mode = "file-system"
  }
}
