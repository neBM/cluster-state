# ExternalSecret for Matrix secrets from Vault
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "matrix-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "matrix-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "db_password"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "db_password"
          }
        },
        {
          secretKey = "registration_shared_secret"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "registration_shared_secret"
          }
        },
        {
          secretKey = "macaroon_secret_key"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "macaroon_secret_key"
          }
        },
        {
          secretKey = "form_secret"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "form_secret"
          }
        },
        {
          secretKey = "turn_shared_secret"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "turn_shared_secret"
          }
        },
        {
          secretKey = "mas_client_secret"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "mas_client_secret"
          }
        },
        {
          secretKey = "mas_admin_token"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "mas_admin_token"
          }
        },
        {
          secretKey = "as_token"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "as_token"
          }
        },
        {
          secretKey = "hs_token"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "hs_token"
          }
        },
        {
          secretKey = "mas_db_password"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "mas_db_password"
          }
        },
        {
          secretKey = "mas_encryption_secret"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "mas_encryption_secret"
          }
        },
        {
          secretKey = "mas_keycloak_client_secret"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "mas_keycloak_client_secret"
          }
        },
        {
          secretKey = "smtp_password"
          remoteRef = {
            key      = "nomad/default/matrix"
            property = "smtp_password"
          }
        }
      ]
    }
  })
}
