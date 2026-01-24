# ExternalSecret for Kibana credentials (username/password)
resource "kubectl_manifest" "kibana_credentials_external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "kibana-credentials"
      namespace = var.namespace
      labels    = local.kibana_labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "kibana-credentials"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "ELASTICSEARCH_USERNAME"
          remoteRef = {
            # Path relative to ClusterSecretStore's vault.path (nomad)
            key      = "default/elk-kibana"
            property = "kibana_username"
          }
        },
        {
          secretKey = "ELASTICSEARCH_PASSWORD"
          remoteRef = {
            key      = "default/elk-kibana"
            property = "kibana_password"
          }
        }
      ]
    }
  })
}

# ExternalSecret for Kibana encryption keys
resource "kubectl_manifest" "kibana_encryption_keys_external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "kibana-encryption-keys"
      namespace = var.namespace
      labels    = local.kibana_labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "kibana-encryption-keys"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY"
          remoteRef = {
            key      = "default/elk-kibana"
            property = "kibana_encryptedSavedObjects_encryptionKey"
          }
        },
        {
          secretKey = "XPACK_REPORTING_ENCRYPTIONKEY"
          remoteRef = {
            key      = "default/elk-kibana"
            property = "kibana_reporting_encryptionKey"
          }
        },
        {
          secretKey = "XPACK_SECURITY_ENCRYPTIONKEY"
          remoteRef = {
            key      = "default/elk-kibana"
            property = "kibana_security_encryptionKey"
          }
        }
      ]
    }
  })
}
