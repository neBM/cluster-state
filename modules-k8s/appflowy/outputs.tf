output "hostname" {
  description = "Public hostname for AppFlowy"
  value       = var.hostname
}

output "namespace" {
  description = "Kubernetes namespace"
  value       = var.namespace
}

output "gotrue_service" {
  description = "GoTrue service name"
  value       = kubernetes_service.gotrue.metadata[0].name
}

output "cloud_service" {
  description = "Cloud API service name"
  value       = kubernetes_service.cloud.metadata[0].name
}

output "postgres_service" {
  description = "PostgreSQL service name"
  value       = kubernetes_service.postgres.metadata[0].name
}

output "redis_service" {
  description = "Redis service name"
  value       = kubernetes_service.redis.metadata[0].name
}
