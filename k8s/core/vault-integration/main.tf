# ClusterSecretStore for External Secrets Operator -> Vault integration
# 
# Prerequisites:
# 1. Vault Kubernetes auth method enabled
# 2. Vault policy 'external-secrets' created
# 3. Vault role 'external-secrets' created

terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}

variable "vault_address" {
  description = "Vault server address"
  type        = string
  default     = "https://vault.brmartin.co.uk"
}

variable "vault_secrets_path" {
  description = "Path to secrets in Vault (KV v2)"
  type        = string
  default     = "nomad"
}

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "vault-backend"
    }
    spec = {
      provider = {
        vault = {
          server  = var.vault_address
          path    = var.vault_secrets_path
          version = "v2"
          auth = {
            kubernetes = {
              mountPath = "kubernetes"
              role      = "external-secrets"
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })
}

output "cluster_secret_store_name" {
  description = "Name of the ClusterSecretStore"
  value       = "vault-backend"
}
