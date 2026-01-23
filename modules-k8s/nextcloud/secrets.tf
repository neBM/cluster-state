# ExternalSecret to pull Nextcloud credentials from Vault
# Vault path: nomad/default/nextcloud

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "nextcloud-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "nextcloud-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "db_password"
          remoteRef = {
            key      = "nomad/default/nextcloud"
            property = "db_password"
          }
        },
        {
          secretKey = "collabora_password"
          remoteRef = {
            key      = "nomad/default/nextcloud"
            property = "collabora_password"
          }
        }
      ]
    }
  })
}
