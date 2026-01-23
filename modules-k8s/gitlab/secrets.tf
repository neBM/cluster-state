# ExternalSecret for GitLab secrets from Vault
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "gitlab-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "gitlab-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "db_password"
          remoteRef = {
            key      = "nomad/default/gitlab"
            property = "db_password"
          }
        }
      ]
    }
  })
}
