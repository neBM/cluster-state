output "service_name" {
  description = "K8s Service name"
  value       = kubernetes_service.nginx_sites.metadata[0].name
}

output "hostnames" {
  description = "External hostnames"
  value       = ["brmartin.co.uk", "www.brmartin.co.uk", "martinilink.co.uk"]
}

output "namespace" {
  description = "Deployed namespace"
  value       = var.namespace
}
