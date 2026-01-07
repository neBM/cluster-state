output "id" {
  description = "The ID of the Nomad job"
  value       = nomad_job.this.id
}

output "name" {
  description = "The name of the Nomad job"
  value       = nomad_job.this.name
}

output "namespace" {
  description = "The namespace of the Nomad job"
  value       = nomad_job.this.namespace
}

output "type" {
  description = "The type of the Nomad job"
  value       = nomad_job.this.type
}

output "allocation_ids" {
  description = "The allocation IDs for the job"
  value       = nomad_job.this.allocation_ids
}

output "task_groups" {
  description = "The task groups of the job"
  value       = nomad_job.this.task_groups
}
