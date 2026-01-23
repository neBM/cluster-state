output "hostname" {
  description = "Public hostname for Nextcloud"
  value       = var.hostname
}

output "collabora_hostname" {
  description = "Public hostname for Collabora"
  value       = var.collabora_hostname
}

output "namespace" {
  description = "Kubernetes namespace"
  value       = var.namespace
}

output "nextcloud_service" {
  description = "Nextcloud service name"
  value       = kubernetes_service.nextcloud.metadata[0].name
}

output "collabora_service" {
  description = "Collabora service name"
  value       = kubernetes_service.collabora.metadata[0].name
}
