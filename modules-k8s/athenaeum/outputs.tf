output "backend_service_url" {
  description = "Internal URL for backend service"
  value       = "http://${kubernetes_service.backend.metadata[0].name}.${var.namespace}.svc.cluster.local:8000"
}

output "frontend_service_url" {
  description = "Internal URL for frontend service"
  value       = "http://${kubernetes_service.frontend.metadata[0].name}.${var.namespace}.svc.cluster.local"
}

output "ingress_url" {
  description = "External URL for Athenaeum"
  value       = "https://${var.domain}"
}

output "namespace" {
  description = "Deployed namespace"
  value       = var.namespace
}
