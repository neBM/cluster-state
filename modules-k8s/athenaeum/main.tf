# Athenaeum - FastAPI + Vue 3 Wiki Application
#
# Components:
# - backend: FastAPI application (port 8000)
# - frontend: Vue 3 SPA served by nginx (port 80)
# - redis: Cache for WebSocket support (port 6379)
#
# External Dependencies:
# - PostgreSQL on martinibar (192.168.1.10:5433)
# - Keycloak SSO (sso.brmartin.co.uk)
# - MinIO for attachments (minio-api.default.svc.cluster.local:9000)

locals {
  labels = {
    app        = "athenaeum"
    managed-by = "terraform"
  }

  backend_labels  = merge(local.labels, { component = "backend" })
  frontend_labels = merge(local.labels, { component = "frontend" })
  redis_labels    = merge(local.labels, { component = "redis" })
}

# =============================================================================
# Redis - Cache for WebSocket support
# =============================================================================

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "athenaeum-redis"
    namespace = var.namespace
    labels    = local.redis_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.redis_labels
    }

    template {
      metadata {
        labels = local.redis_labels
      }

      spec {
        container {
          name  = "redis"
          image = var.redis_image

          port {
            container_port = 6379
            name           = "redis"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "athenaeum-redis"
    namespace = var.namespace
    labels    = local.redis_labels
  }

  spec {
    selector = local.redis_labels

    port {
      port        = 6379
      target_port = 6379
      protocol    = "TCP"
      name        = "redis"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Backend - FastAPI Application
# =============================================================================

resource "kubernetes_deployment" "backend" {
  metadata {
    name      = "athenaeum-backend"
    namespace = var.namespace
    labels    = local.backend_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.backend_labels
    }

    template {
      metadata {
        labels = local.backend_labels
      }

      spec {
        image_pull_secrets {
          name = "gitlab-registry"
        }

        container {
          name  = "backend"
          image = var.backend_image

          port {
            container_port = 8000
            name           = "http"
          }

          # Environment variables from athenaeum-secrets
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }

          env {
            name = "KEYCLOAK_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "KEYCLOAK_URL"
              }
            }
          }

          env {
            name = "KEYCLOAK_REALM"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "KEYCLOAK_REALM"
              }
            }
          }

          env {
            name = "KEYCLOAK_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "KEYCLOAK_CLIENT_ID"
              }
            }
          }

          env {
            name = "KEYCLOAK_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "KEYCLOAK_CLIENT_SECRET"
              }
            }
          }

          env {
            name = "REDIS_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "REDIS_URL"
              }
            }
          }

          env {
            name = "MINIO_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "MINIO_URL"
              }
            }
          }

          env {
            name = "MINIO_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "MINIO_ACCESS_KEY"
              }
            }
          }

          env {
            name = "MINIO_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "MINIO_SECRET_KEY"
              }
            }
          }

          env {
            name = "MINIO_BUCKET"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.athenaeum.metadata[0].name
                key  = "MINIO_BUCKET"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "backend" {
  metadata {
    name      = "athenaeum-backend"
    namespace = var.namespace
    labels    = local.backend_labels
  }

  spec {
    selector = local.backend_labels

    port {
      port        = 8000
      target_port = 8000
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Frontend - Vue 3 SPA (nginx)
# =============================================================================

# Frontend runtime configuration (injected at page load)
resource "kubernetes_config_map" "frontend_config" {
  metadata {
    name      = "athenaeum-frontend-config"
    namespace = var.namespace
    labels    = local.frontend_labels
  }

  data = {
    "config.js" = <<-EOT
      // Runtime configuration for Athenaeum frontend
      // This file is injected by Kubernetes and loaded before the app starts
      window.APP_CONFIG = {
        apiUrl: 'https://${var.domain}',
        wsUrl: 'wss://${var.domain}',
        keycloak: {
          url: '${var.keycloak_url}',
          realm: '${var.keycloak_realm}',
          clientId: '${var.keycloak_client_id}'
        }
      };
    EOT
  }
}

resource "kubernetes_deployment" "frontend" {
  metadata {
    name      = "athenaeum-frontend"
    namespace = var.namespace
    labels    = local.frontend_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.frontend_labels
    }

    template {
      metadata {
        labels = local.frontend_labels
      }

      spec {
        image_pull_secrets {
          name = "gitlab-registry"
        }

        container {
          name  = "frontend"
          image = var.frontend_image

          port {
            container_port = 80
            name           = "http"
          }

          # Mount runtime config from ConfigMap
          volume_mount {
            name       = "frontend-config"
            mount_path = "/usr/share/nginx/html/config.js"
            sub_path   = "config.js"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Volume for runtime configuration
        volume {
          name = "frontend-config"
          config_map {
            name = kubernetes_config_map.frontend_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "frontend" {
  metadata {
    name      = "athenaeum-frontend"
    namespace = var.namespace
    labels    = local.frontend_labels
  }

  spec {
    selector = local.frontend_labels

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Ingress - Traefik (athenaeum.brmartin.co.uk)
# =============================================================================

resource "kubernetes_ingress_v1" "athenaeum" {
  metadata {
    name      = "athenaeum"
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = [var.domain]
      secret_name = "wildcard-brmartin-tls"
    }

    # Frontend (root path)
    rule {
      host = var.domain
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.frontend.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }

    # Backend API (under /api)
    rule {
      host = var.domain
      http {
        path {
          path      = "/api"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.backend.metadata[0].name
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }
}
