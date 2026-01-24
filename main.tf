terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  backend "pg" {}
}

# =============================================================================
# Nomad Services (NOT migrated to K8s)
# =============================================================================

# ELK Stack - MIGRATED TO KUBERNETES (see modules-k8s/elk/)
# The Nomad ELK job has been stopped and data migrated to K8s.
# Original module removed 2026-01-24.

# Jayne Martin Counselling - Static website (consider migrating later)
module "jayne_martin_counselling" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/jayne-martin-counselling/jobspec.nomad.hcl"
}
