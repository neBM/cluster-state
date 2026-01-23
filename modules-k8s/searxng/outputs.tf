output "service_name" {
  description = "K8s Service name"
  value       = kubernetes_service.searxng.metadata[0].name
}

output "hostname" {
  description = "External hostname"
  value       = var.hostname
}

output "namespace" {
  description = "Deployed namespace"
  value       = var.namespace
}
