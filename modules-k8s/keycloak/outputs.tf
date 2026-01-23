output "service_name" {
  description = "Name of the Keycloak service"
  value       = kubernetes_service.keycloak.metadata[0].name
}

output "namespace" {
  description = "Namespace where Keycloak is deployed"
  value       = var.namespace
}

output "hostname" {
  description = "Hostname for Keycloak SSO"
  value       = var.hostname
}
