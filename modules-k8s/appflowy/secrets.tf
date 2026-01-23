# ExternalSecret to pull AppFlowy credentials from Vault
# Vault path: nomad/default/appflowy

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "appflowy-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "appflowy-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "GOTRUE_JWT_SECRET"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "GOTRUE_JWT_SECRET"
          }
        },
        {
          secretKey = "OIDC_CLIENT_SECRET"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "OIDC_CLIENT_SECRET"
          }
        },
        {
          secretKey = "PGPASSWORD"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "PGPASSWORD"
          }
        },
        {
          secretKey = "S3_SECRET_KEY"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "S3_SECRET_KEY"
          }
        },
        {
          secretKey = "SMTP_USERNAME"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "SMTP_USERNAME"
          }
        },
        {
          secretKey = "SMTP_PASSWORD"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "SMTP_PASSWORD"
          }
        },
        {
          secretKey = "SMTP_ADMIN_ADDRESS"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "SMTP_ADMIN_ADDRESS"
          }
        },
        {
          secretKey = "SMTP_FROM_ADDRESS"
          remoteRef = {
            key      = "nomad/default/appflowy"
            property = "SMTP_FROM_ADDRESS"
          }
        }
      ]
    }
  })
}
