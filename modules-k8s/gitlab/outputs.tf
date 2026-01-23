output "gitlab_service" {
  description = "GitLab service name"
  value       = kubernetes_service.gitlab.metadata[0].name
}

output "gitlab_hostname" {
  description = "GitLab hostname"
  value       = var.gitlab_hostname
}

output "registry_hostname" {
  description = "Registry hostname"
  value       = var.registry_hostname
}

output "ssh_port" {
  description = "Git SSH port"
  value       = var.ssh_port
}
