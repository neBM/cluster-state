# Output useful information about deployed jobs

# ELK has been migrated to Kubernetes - see module.k8s_elk
# The elk_job_info output has been removed as the Nomad job no longer exists.

output "nomad_provider_address" {
  description = "Nomad server address used by provider"
  value       = var.nomad_address
}

output "environment" {
  description = "Current environment"
  value       = var.environment
}
