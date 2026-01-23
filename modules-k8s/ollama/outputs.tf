output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service.ollama.metadata[0].name
}

output "service_url" {
  description = "Internal URL for ollama API"
  value       = "http://${kubernetes_service.ollama.metadata[0].name}.${var.namespace}.svc.cluster.local:11434"
}

output "namespace" {
  description = "Namespace where ollama is deployed"
  value       = var.namespace
}
