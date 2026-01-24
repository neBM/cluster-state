terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  backend "pg" {}
}

# =============================================================================
# Nomad Services - ALL MIGRATED TO KUBERNETES
# =============================================================================

# All services have been migrated to Kubernetes (K3s).
# See kubernetes.tf for K8s module definitions.
#
# Migration history:
# - 2026-01-24: ELK stack migrated (see modules-k8s/elk/)
# - 2026-01-24: Jayne Martin Counselling migrated (see modules-k8s/jayne-martin-counselling/)
