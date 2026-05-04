output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service_v1.overseerr.metadata[0].name
}

output "hostname" {
  description = "Hostname for external access"
  value       = var.hostname
}

output "namespace" {
  description = "Namespace where overseerr is deployed"
  value       = var.namespace
}
