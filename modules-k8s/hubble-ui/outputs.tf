output "hostname" {
  description = "Hubble UI hostname"
  value       = var.hostname
}

output "ingress_name" {
  description = "Name of the Ingress resource"
  value       = kubernetes_ingress_v1.hubble_ui.metadata[0].name
}

output "ingress_namespace" {
  description = "Namespace of the Ingress resource"
  value       = kubernetes_ingress_v1.hubble_ui.metadata[0].namespace
}
