output "service_url" {
  description = "Internal cluster URL for the dissertation service"
  value       = "http://${kubernetes_service.app.metadata[0].name}.${var.namespace}.svc.cluster.local:8000"
}

output "ingress_url" {
  description = "External URL for the dashboard"
  value       = "https://${var.domain}"
}

output "namespace" {
  description = "Deployed namespace"
  value       = var.namespace
}
