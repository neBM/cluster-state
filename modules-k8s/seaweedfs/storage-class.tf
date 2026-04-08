resource "kubernetes_storage_class" "seaweedfs" {
  metadata {
    name   = "seaweedfs"
    labels = local.labels
  }

  storage_provisioner    = "seaweedfs-csi-driver"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    collection  = "default"
    replication = var.replication
  }

  mount_options = [
    "concurrentWriters=8",
    "chunkSizeLimitMB=2",
  ]
}
