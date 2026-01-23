output "synapse_service" {
  description = "Synapse service name"
  value       = kubernetes_service.synapse.metadata[0].name
}

output "mas_service" {
  description = "MAS service name"
  value       = kubernetes_service.mas.metadata[0].name
}

output "element_service" {
  description = "Element service name"
  value       = kubernetes_service.element.metadata[0].name
}

output "cinny_service" {
  description = "Cinny service name"
  value       = kubernetes_service.cinny.metadata[0].name
}

output "synapse_hostname" {
  description = "Synapse hostname"
  value       = var.synapse_hostname
}

output "mas_hostname" {
  description = "MAS hostname"
  value       = var.mas_hostname
}

output "element_hostname" {
  description = "Element hostname"
  value       = var.element_hostname
}

output "cinny_hostname" {
  description = "Cinny hostname"
  value       = var.cinny_hostname
}
