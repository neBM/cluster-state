output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service.overseerr.metadata[0].name
}

output "ingress_hostname" {
  description = "Hostname configured in ingress"
  value       = kubernetes_ingress_v1.overseerr.spec[0].rule[0].host
}

output "pvc_name" {
  description = "Name of the persistent volume claim"
  value       = kubernetes_persistent_volume_claim.overseerr_config.metadata[0].name
}
