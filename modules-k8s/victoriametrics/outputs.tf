output "service_name" {
  description = "VictoriaMetrics service name"
  value       = kubernetes_service.victoriametrics.metadata[0].name
}

output "service_url" {
  description = "VictoriaMetrics internal service URL"
  value       = "http://${kubernetes_service.victoriametrics.metadata[0].name}.${local.namespace}.svc.cluster.local:8428"
}

output "ingress_url" {
  description = "VictoriaMetrics external URL"
  value       = "https://${var.ingress_hostname}"
}
