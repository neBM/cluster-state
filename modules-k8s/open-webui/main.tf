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
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "open-webui-data-sw"
    namespace = var.namespace
    labels = {
      app         = "open-webui"
      managed-by  = "terraform"
      environment = "prod"
    }
  }
  spec {
    storage_class_name = "seaweedfs"
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
            value = "redis://valkey.default.svc.cluster.local:6379/0"
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
            name              = "data"
            mount_path        = "/app/backend/data"
            mount_propagation = "HostToContainer"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "800Mi"
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
    kubernetes_persistent_volume_claim.data,
  ]
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

# Open WebUI secrets are managed outside Terraform as a plain Kubernetes Secret.
# Secret name: open-webui-secrets
# Keys: OAUTH_CLIENT_SECRET, WEBUI_SECRET_KEY, DATABASE_URL, POSTGRES_PASSWORD
