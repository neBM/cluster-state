# ExternalSecret to sync MinIO root credentials from Vault
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.app_name}-secrets"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "${local.app_name}-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "MINIO_ROOT_USER"
          remoteRef = {
            # Path relative to ClusterSecretStore's vault.path (nomad)
            key      = "default/minio"
            property = "MINIO_ROOT_USER"
          }
        },
        {
          secretKey = "MINIO_ROOT_PASSWORD"
          remoteRef = {
            key      = "default/minio"
            property = "MINIO_ROOT_PASSWORD"
          }
        }
      ]
    }
  })
}
