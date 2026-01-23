output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service.vaultwarden.metadata[0].name
}

output "hostname" {
  description = "Hostname for external access"
  value       = var.hostname
}

output "namespace" {
  description = "Namespace where vaultwarden is deployed"
  value       = var.namespace
}
