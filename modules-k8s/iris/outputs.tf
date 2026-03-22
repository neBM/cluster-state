output "service_url" {
  description = "In-cluster URL for Iris (unified API + SPA server)"
  value       = "http://iris.${var.namespace}.svc.cluster.local:8080"
}

output "ingress_url" {
  description = "Public URL for the Iris web UI"
  value       = "https://${var.hostname}"
}

output "namespace" {
  description = "Kubernetes namespace where Iris is deployed"
  value       = var.namespace
}
