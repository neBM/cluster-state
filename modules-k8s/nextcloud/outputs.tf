output "hostname" {
  description = "Public hostname for Nextcloud"
  value       = var.hostname
}

output "namespace" {
  description = "Kubernetes namespace"
  value       = var.namespace
}

output "nextcloud_service" {
  description = "Nextcloud service name"
  value       = kubernetes_service.nextcloud.metadata[0].name
}
