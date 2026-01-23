output "service_name" {
  description = "Name of the MinIO service"
  value       = kubernetes_service.minio_api.metadata[0].name
}

output "console_service_name" {
  description = "Name of the MinIO console service"
  value       = kubernetes_service.minio_console.metadata[0].name
}

output "namespace" {
  description = "Namespace where MinIO is deployed"
  value       = var.namespace
}

output "console_hostname" {
  description = "Hostname for MinIO console"
  value       = var.console_hostname
}

output "s3_endpoint" {
  description = "Internal S3 API endpoint (for K8s services)"
  value       = "http://${kubernetes_service.minio_api.metadata[0].name}.${var.namespace}.svc.cluster.local:9000"
}

output "s3_nodeport" {
  description = "NodePort for S3 API (for Nomad services)"
  value       = kubernetes_service.minio_api.spec[0].port[0].node_port
}
