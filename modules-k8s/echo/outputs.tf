output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service.echo.metadata[0].name
}

output "cluster_dns" {
  description = "Cluster DNS name for the service"
  value       = "${kubernetes_service.echo.metadata[0].name}.${var.namespace}.svc.cluster.local"
}
