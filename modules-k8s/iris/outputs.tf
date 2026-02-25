output "api_service_url" {
  description = "In-cluster URL for the Iris API"
  value       = "http://iris-api.${var.namespace}.svc.cluster.local:8080"
}

output "web_service_url" {
  description = "In-cluster URL for the Iris web frontend"
  value       = "http://iris-web.${var.namespace}.svc.cluster.local:8080"
}

output "ingress_url" {
  description = "Public URL for the Iris web UI"
  value       = "https://${var.hostname}"
}

output "namespace" {
  description = "Kubernetes namespace where Iris is deployed"
  value       = var.namespace
}
