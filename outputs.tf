# Output useful information about deployed jobs

output "elk_job_info" {
  description = "Information about the ELK stack job"
  value = {
    id        = module.elk.id
    name      = module.elk.name
    namespace = module.elk.namespace
  }
}

output "nomad_provider_address" {
  description = "Nomad server address used by provider"
  value       = var.nomad_address
}

output "environment" {
  description = "Current environment"
  value       = var.environment
}
