# Open WebUI - LLM chat interface
#
# Components:
# - open-webui: Main web application (port 8080)
# - valkey: Redis-compatible cache (port 6379)
#
# External PostgreSQL on martinibar (192.168.1.10:5433)
# Connects to Ollama via NodePort 31434 on Hestia
# OAuth via Keycloak

locals {
  app_labels = {
    app        = "open-webui"
    component  = "app"
    managed-by = "terraform"
  }
  valkey_labels = {
    app        = "open-webui"
    component  = "valkey"
    managed-by = "terraform"
  }
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "open-webui-data"
    namespace = var.namespace
    annotations = {
      "volume-name" = "ollama_data"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# =============================================================================
# Open WebUI Deployment
# =============================================================================

resource "kubernetes_deployment" "open_webui" {
  metadata {
    name      = "open-webui"
    namespace = var.namespace
    labels    = local.app_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.app_labels
    }

    template {
      metadata {
        labels = local.app_labels
      }

      spec {
        container {
          name  = "open-webui"
          image = "${var.image}:${var.image_tag}"

          port {
            container_port = 8080
          }

          env {
            name  = "OLLAMA_BASE_URL"
            value = "http://ollama.default.svc.cluster.local:11434"
          }

          env {
            name  = "ENABLE_OAUTH_SIGNUP"
            value = "true"
          }

          env {
            name  = "OAUTH_CLIENT_ID"
            value = "open-webui"
          }

          env {
            name  = "OPENID_PROVIDER_URL"
            value = "https://sso.brmartin.co.uk/realms/prod/.well-known/openid-configuration"
          }

          env {
            name  = "OAUTH_PROVIDER_NAME"
            value = "Keycloak"
          }

          env {
            name  = "OPENID_REDIRECT_URI"
            value = "https://${var.hostname}/oauth/oidc/callback"
          }

          env {
            name  = "JWT_EXPIRES_IN"
            value = "1h"
          }

          env {
            name  = "WEBUI_SESSION_COOKIE_SECURE"
            value = "true"
          }

          env {
            name  = "VECTOR_DB"
            value = "pgvector"
          }

          env {
            name  = "REDIS_URL"
            value = "redis://open-webui-valkey.default.svc.cluster.local:6379/0"
          }

          env {
            name  = "CORS_ALLOW_ORIGIN"
            value = "https://${var.hostname}"
          }

          env {
            name  = "RAG_EMBEDDING_ENGINE"
            value = "ollama"
          }

          env {
            name = "OAUTH_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "open-webui-secrets"
                key  = "OAUTH_CLIENT_SECRET"
              }
            }
          }

          env {
            name = "WEBUI_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "open-webui-secrets"
                key  = "WEBUI_SECRET_KEY"
              }
            }
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "open-webui-secrets"
                key  = "DATABASE_URL"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/backend/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubectl_manifest.external_secret,
    kubernetes_deployment.valkey,
    kubernetes_persistent_volume_claim.data,
  ]
}

# =============================================================================
# Valkey (Redis) Deployment
# =============================================================================

resource "kubernetes_deployment" "valkey" {
  metadata {
    name      = "open-webui-valkey"
    namespace = var.namespace
    labels    = local.valkey_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.valkey_labels
    }

    template {
      metadata {
        labels = local.valkey_labels
      }

      spec {
        container {
          name  = "valkey"
          image = "${var.valkey_image}:${var.valkey_tag}"

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "valkey" {
  metadata {
    name      = "open-webui-valkey"
    namespace = var.namespace
    labels    = local.valkey_labels
  }

  spec {
    selector = local.valkey_labels

    port {
      port        = 6379
      target_port = 6379
    }
  }
}

# =============================================================================
# Open WebUI Service and IngressRoute
# =============================================================================

resource "kubernetes_service" "open_webui" {
  metadata {
    name      = "open-webui"
    namespace = var.namespace
    labels    = local.app_labels
  }

  spec {
    selector = local.app_labels

    port {
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "open-webui"
      namespace = var.namespace
      labels    = local.app_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.open_webui.metadata[0].name
              port = 80
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# =============================================================================
# External Secret
# =============================================================================

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "open-webui-secrets"
      namespace = var.namespace
      labels    = local.app_labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "open-webui-secrets"
      }
      data = [
        {
          secretKey = "OAUTH_CLIENT_SECRET"
          remoteRef = {
            key      = "nomad/default/open-webui"
            property = "OAUTH_CLIENT_SECRET"
          }
        },
        {
          secretKey = "WEBUI_SECRET_KEY"
          remoteRef = {
            key      = "nomad/default/open-webui"
            property = "WEBUI_SECRET_KEY"
          }
        },
        {
          secretKey = "DATABASE_URL"
          remoteRef = {
            key      = "nomad/default/open-webui"
            property = "DATABASE_URL"
          }
        },
        {
          secretKey = "POSTGRES_PASSWORD"
          remoteRef = {
            key      = "nomad/default/open-webui"
            property = "POSTGRES_PASSWORD"
          }
        }
      ]
    }
  })
}
