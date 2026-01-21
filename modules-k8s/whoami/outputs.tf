output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service.whoami.metadata[0].name
}

output "ingress_hostname" {
  description = "Hostname configured in ingress"
  value       = kubernetes_ingress_v1.whoami.spec[0].rule[0].host
}
