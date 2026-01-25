# GitLab Multi-Container Outputs

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

# Service names for inter-module references
output "webservice_service" {
  description = "Webservice service name"
  value       = kubernetes_service.webservice.metadata[0].name
}

output "workhorse_service" {
  description = "Workhorse service name (main entry point)"
  value       = kubernetes_service.workhorse.metadata[0].name
}

output "gitaly_service" {
  description = "Gitaly service name"
  value       = kubernetes_service.gitaly.metadata[0].name
}

output "redis_service" {
  description = "Redis service name"
  value       = kubernetes_service.redis.metadata[0].name
}

output "registry_service" {
  description = "Registry service name"
  value       = kubernetes_service.registry.metadata[0].name
}

# Service endpoints (for debugging)
output "internal_endpoints" {
  description = "Internal service endpoints"
  value = {
    webservice = "http://gitlab-webservice:8080"
    workhorse  = "http://gitlab-workhorse:8181"
    gitaly     = "tcp://gitlab-gitaly:8075"
    redis      = "redis://gitlab-redis:6379"
    registry   = "http://gitlab-registry:5000"
  }
}
