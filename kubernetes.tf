# Kubernetes Configuration for PoC Migration
#
# This file configures the Kubernetes provider and K8s-based modules.
# The K8s cluster must be installed separately (see specs/003-nomad-to-kubernetes/quickstart.md)
#
# To enable K8s modules, set the environment variable:
#   export TF_VAR_enable_k8s=true

variable "enable_k8s" {
  description = "Enable Kubernetes modules (requires K3s cluster to be installed)"
  type        = bool
  default     = false
}

variable "k8s_config_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/k3s-config"
}

variable "k8s_context" {
  description = "Kubernetes context to use"
  type        = string
  default     = "default"
}

# Kubernetes provider - only active when K8s is enabled
provider "kubernetes" {
  config_path    = var.enable_k8s ? pathexpand(var.k8s_config_path) : null
  config_context = var.enable_k8s ? var.k8s_context : null
}

# kubectl provider for CRDs (VPA, ExternalSecret, CiliumNetworkPolicy)
provider "kubectl" {
  config_path    = var.enable_k8s ? pathexpand(var.k8s_config_path) : null
  config_context = var.enable_k8s ? var.k8s_context : null
}

# =============================================================================
# Kubernetes Modules (PoC)
# =============================================================================

# Vault integration for External Secrets Operator
module "k8s_vault_integration" {
  count  = var.enable_k8s ? 1 : 0
  source = "./k8s/core/vault-integration"
}

# Whoami - Stateless demo service
module "k8s_whoami" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/whoami"

  namespace = "default"
  vpa_mode  = "Off" # Recommendations only
}

# Echo - Service mesh testing
module "k8s_echo" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/echo"

  namespace       = "default"
  allowed_sources = ["whoami"]
}

# Overseerr (K8s) - Stateful service with litestream
# Uses different URL (overseerr-k8s.brmartin.co.uk) during PoC
module "k8s_overseerr" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/overseerr"

  namespace = "default"
  vpa_mode  = "Auto"

  # Use separate bucket to avoid conflict with Nomad instance
  litestream_bucket = "overseerr-k8s-litestream"

  # MinIO endpoint via Consul DNS (CoreDNS configured to forward .consul)
  # This allows K8s pods to reach Nomad services regardless of which node they run on
  minio_endpoint = "http://minio-minio.service.consul:9000"

  depends_on = [module.k8s_vault_integration]
}
