output "s3_endpoint" {
  description = "S3 API endpoint (internal)"
  value       = "http://seaweedfs-s3.${var.namespace}.svc.cluster.local:8333"
}

output "filer_endpoint" {
  description = "Filer HTTP endpoint (internal)"
  value       = "http://seaweedfs-filer.${var.namespace}.svc.cluster.local:8888"
}

output "master_endpoint" {
  description = "Master HTTP endpoint (internal)"
  value       = "seaweedfs-master.${var.namespace}.svc.cluster.local:9333"
}

output "storage_class_name" {
  description = "StorageClass name for PVCs"
  value       = kubernetes_storage_class.seaweedfs.metadata[0].name
}
