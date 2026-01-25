# AppFlowy - Collaborative documentation platform
#
# Components:
# - gotrue: Authentication service (port 9999)
# - cloud: Main API server (port 8000)
# - admin-frontend: Admin UI (port 8000)
# - worker: Background worker (port 8000)
# - web: Public web UI (port 80)
# - postgres: pgvector database (port 5432)
# - redis: Cache (port 6379)
#
# PostgreSQL data stored on hostPath (GlusterFS mount on Hestia)
# MinIO used for S3 storage (already migrated to K8s)
# Keycloak used for OIDC (already migrated to K8s)

locals {
  labels = {
    app = "appflowy"
  }

  # Elastic Agent log routing annotations
  # Routes logs to logs-kubernetes.container_logs.appflowy-* index
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.appflowy"
  }

  # K8s service DNS names (replacing Consul DNS)
  postgres_host = "appflowy-postgres.${var.namespace}.svc.cluster.local"
  redis_host    = "appflowy-redis.${var.namespace}.svc.cluster.local"
  gotrue_host   = "appflowy-gotrue.${var.namespace}.svc.cluster.local"
}

# =============================================================================
# PostgreSQL (pgvector)
# =============================================================================

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "appflowy-postgres"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "postgres" })
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # Required for hostPath
    }

    selector {
      match_labels = merge(local.labels, { component = "postgres" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "postgres" })
        annotations = local.elastic_log_annotations
      }

      spec {
        # GlusterFS NFS mounts (/storage/v/) are available on all nodes

        container {
          name  = "postgres"
          image = var.postgres_image

          port {
            container_port = 5432
          }

          env {
            name  = "POSTGRES_USER"
            value = "appflowy"
          }

          env {
            name  = "POSTGRES_DB"
            value = "appflowy"
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "PGPASSWORD"
              }
            }
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "appflowy"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "appflowy"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "postgres-data"
          host_path {
            path = var.postgres_data_path
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "appflowy-postgres"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "postgres" })
  }

  spec {
    selector = merge(local.labels, { component = "postgres" })

    port {
      port        = 5432
      target_port = 5432
    }
  }
}

# =============================================================================
# Redis
# =============================================================================

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "appflowy-redis"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "redis" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = merge(local.labels, { component = "redis" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "redis" })
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "redis"
          image = var.redis_image

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
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
    name      = "appflowy-redis"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "redis" })
  }

  spec {
    selector = merge(local.labels, { component = "redis" })

    port {
      port        = 6379
      target_port = 6379
    }
  }
}

# =============================================================================
# GoTrue (Authentication)
# =============================================================================

resource "kubernetes_deployment" "gotrue" {
  metadata {
    name      = "appflowy-gotrue"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "gotrue" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = merge(local.labels, { component = "gotrue" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "gotrue" })
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "gotrue"
          image = var.gotrue_image

          port {
            container_port = 9999
          }

          env {
            name  = "PORT"
            value = "9999"
          }

          env {
            name  = "API_EXTERNAL_URL"
            value = "https://${var.hostname}/gotrue"
          }

          env {
            name  = "GOTRUE_DB_DRIVER"
            value = "postgres"
          }

          env {
            name  = "GOTRUE_DISABLE_SIGNUP"
            value = "true"
          }

          env {
            name  = "GOTRUE_EXTERNAL_KEYCLOAK_ENABLED"
            value = "true"
          }

          env {
            name  = "GOTRUE_EXTERNAL_KEYCLOAK_URL"
            value = var.keycloak_url
          }

          env {
            name  = "GOTRUE_EXTERNAL_KEYCLOAK_CLIENT_ID"
            value = var.keycloak_client_id
          }

          env {
            name  = "GOTRUE_EXTERNAL_KEYCLOAK_REDIRECT_URI"
            value = "https://${var.hostname}/gotrue/callback"
          }

          env {
            name  = "GOTRUE_JWT_EXP"
            value = "604800"
          }

          env {
            name  = "GOTRUE_MAILER_AUTOCONFIRM"
            value = "false"
          }

          env {
            name  = "GOTRUE_MAILER_URLPATHS_CONFIRMATION"
            value = "/gotrue/verify"
          }

          env {
            name  = "GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE"
            value = "/gotrue/verify"
          }

          env {
            name  = "GOTRUE_MAILER_URLPATHS_INVITE"
            value = "/gotrue/verify"
          }

          env {
            name  = "GOTRUE_MAILER_URLPATHS_RECOVERY"
            value = "/gotrue/verify"
          }

          env {
            name  = "GOTRUE_SITE_URL"
            value = "appflowy-flutter://"
          }

          env {
            name  = "GOTRUE_SMTP_HOST"
            value = var.smtp_host
          }

          env {
            name  = "GOTRUE_SMTP_PORT"
            value = var.smtp_port
          }

          env {
            name  = "GOTRUE_URI_ALLOW_LIST"
            value = "https://${var.hostname}"
          }

          # Secrets from ExternalSecret
          env {
            name = "GOTRUE_JWT_SECRET"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "GOTRUE_JWT_SECRET"
              }
            }
          }

          env {
            name = "GOTRUE_EXTERNAL_KEYCLOAK_SECRET"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "OIDC_CLIENT_SECRET"
              }
            }
          }

          env {
            name = "GOTRUE_SMTP_USER"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "SMTP_USERNAME"
              }
            }
          }

          env {
            name = "GOTRUE_SMTP_PASS"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "SMTP_PASSWORD"
              }
            }
          }

          env {
            name = "GOTRUE_SMTP_ADMIN_EMAIL"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "SMTP_ADMIN_ADDRESS"
              }
            }
          }

          # DATABASE_URL constructed with password
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "PGPASSWORD"
              }
            }
          }

          env {
            name  = "DATABASE_URL"
            value = "postgres://appflowy:$(PGPASSWORD)@${local.postgres_host}/appflowy?search_path=auth"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 9999
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 9999
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgres,
    kubectl_manifest.external_secret
  ]
}

resource "kubernetes_service" "gotrue" {
  metadata {
    name      = "appflowy-gotrue"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "gotrue" })
  }

  spec {
    selector = merge(local.labels, { component = "gotrue" })

    port {
      port        = 9999
      target_port = 9999
    }
  }
}

# =============================================================================
# Cloud (Main API)
# =============================================================================

resource "kubernetes_deployment" "cloud" {
  metadata {
    name      = "appflowy-cloud"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "cloud" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = merge(local.labels, { component = "cloud" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "cloud" })
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "cloud"
          image = var.cloud_image

          port {
            container_port = 8000
          }

          env {
            name  = "RUST_LOG"
            value = "info"
          }

          env {
            name  = "APPFLOWY_ENVIRONMENT"
            value = "production"
          }

          env {
            name  = "APPFLOWY_REDIS_URI"
            value = "redis://${local.redis_host}:6379"
          }

          env {
            name  = "APPFLOWY_GOTRUE_BASE_URL"
            value = "http://${local.gotrue_host}:9999"
          }

          env {
            name  = "APPFLOWY_S3_CREATE_BUCKET"
            value = "false"
          }

          env {
            name  = "APPFLOWY_S3_USE_MINIO"
            value = "true"
          }

          env {
            name  = "APPFLOWY_S3_MINIO_URL"
            value = var.minio_endpoint
          }

          env {
            name  = "APPFLOWY_S3_ACCESS_KEY"
            value = var.minio_access_key
          }

          env {
            name  = "APPFLOWY_S3_BUCKET"
            value = var.minio_bucket
          }

          env {
            name  = "APPFLOWY_ACCESS_CONTROL"
            value = "true"
          }

          env {
            name  = "APPFLOWY_DATABASE_MAX_CONNECTIONS"
            value = "40"
          }

          env {
            name  = "APPFLOWY_WEB_URL"
            value = "https://${var.hostname}"
          }

          env {
            name  = "APPFLOWY_BASE_URL"
            value = "https://${var.hostname}"
          }

          env {
            name  = "APPFLOWY_MAILER_SMTP_HOST"
            value = var.smtp_host
          }

          env {
            name  = "APPFLOWY_MAILER_SMTP_PORT"
            value = var.smtp_port
          }

          # Secrets from ExternalSecret
          env {
            name = "APPFLOWY_GOTRUE_JWT_SECRET"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "GOTRUE_JWT_SECRET"
              }
            }
          }

          env {
            name = "APPFLOWY_S3_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "S3_SECRET_KEY"
              }
            }
          }

          env {
            name = "APPFLOWY_MAILER_SMTP_USERNAME"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "SMTP_USERNAME"
              }
            }
          }

          env {
            name = "APPFLOWY_MAILER_SMTP_PASSWORD"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "SMTP_PASSWORD"
              }
            }
          }

          env {
            name = "APPFLOWY_MAILER_SMTP_EMAIL"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "SMTP_FROM_ADDRESS"
              }
            }
          }

          # DATABASE_URL constructed with password
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "PGPASSWORD"
              }
            }
          }

          env {
            name  = "APPFLOWY_DATABASE_URL"
            value = "postgres://appflowy:$(PGPASSWORD)@${local.postgres_host}/appflowy"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgres,
    kubernetes_deployment.redis,
    kubernetes_deployment.gotrue,
    kubectl_manifest.external_secret
  ]
}

resource "kubernetes_service" "cloud" {
  metadata {
    name      = "appflowy-cloud"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "cloud" })
  }

  spec {
    selector = merge(local.labels, { component = "cloud" })

    port {
      port        = 8000
      target_port = 8000
    }
  }
}

# =============================================================================
# Worker (Background Jobs)
# =============================================================================

resource "kubernetes_deployment" "worker" {
  metadata {
    name      = "appflowy-worker"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "worker" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = merge(local.labels, { component = "worker" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "worker" })
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "worker"
          image = var.worker_image

          port {
            container_port = 8000
          }

          env {
            name  = "RUST_LOG"
            value = "info"
          }

          env {
            name  = "APPFLOWY_ENVIRONMENT"
            value = "production"
          }

          env {
            name  = "APPFLOWY_WORKER_REDIS_URL"
            value = "redis://${local.redis_host}:6379"
          }

          env {
            name  = "APPFLOWY_WORKER_ENVIRONMENT"
            value = "production"
          }

          env {
            name  = "APPFLOWY_WORKER_DATABASE_NAME"
            value = "appflowy"
          }

          env {
            name  = "APPFLOWY_WORKER_IMPORT_TICK_INTERVAL"
            value = "30"
          }

          env {
            name  = "APPFLOWY_S3_USE_MINIO"
            value = "true"
          }

          env {
            name  = "APPFLOWY_S3_MINIO_URL"
            value = var.minio_endpoint
          }

          env {
            name  = "APPFLOWY_S3_ACCESS_KEY"
            value = var.minio_access_key
          }

          env {
            name  = "APPFLOWY_S3_BUCKET"
            value = var.minio_bucket
          }

          # Secrets from ExternalSecret
          env {
            name = "APPFLOWY_S3_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "S3_SECRET_KEY"
              }
            }
          }

          # DATABASE_URL constructed with password
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "appflowy-secrets"
                key  = "PGPASSWORD"
              }
            }
          }

          env {
            name  = "APPFLOWY_WORKER_DATABASE_URL"
            value = "postgres://appflowy:$(PGPASSWORD)@${local.postgres_host}/appflowy"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgres,
    kubernetes_deployment.redis,
    kubectl_manifest.external_secret
  ]
}

resource "kubernetes_service" "worker" {
  metadata {
    name      = "appflowy-worker"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "worker" })
  }

  spec {
    selector = merge(local.labels, { component = "worker" })

    port {
      port        = 8000
      target_port = 8000
    }
  }
}

# =============================================================================
# Admin Frontend
# =============================================================================

resource "kubernetes_deployment" "admin_frontend" {
  metadata {
    name      = "appflowy-admin-frontend"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "admin-frontend" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = merge(local.labels, { component = "admin-frontend" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "admin-frontend" })
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "admin-frontend"
          image = var.web_image

          port {
            container_port = 8000
          }

          env {
            name  = "APPFLOWY_BASE_URL"
            value = "https://${var.hostname}"
          }

          # Admin frontend uses internal gotrue URL (not public /gotrue path)
          env {
            name  = "APPFLOWY_GOTRUE_BASE_URL"
            value = "http://${local.gotrue_host}:9999"
          }

          env {
            name  = "APPFLOWY_WS_BASE_URL"
            value = "wss://${var.hostname}/ws/v2"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
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

resource "kubernetes_service" "admin_frontend" {
  metadata {
    name      = "appflowy-admin-frontend"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "admin-frontend" })
  }

  spec {
    selector = merge(local.labels, { component = "admin-frontend" })

    port {
      port        = 8000
      target_port = 8000
    }
  }
}

# =============================================================================
# Web (Public Frontend)
# =============================================================================

resource "kubernetes_deployment" "web" {
  metadata {
    name      = "appflowy-web"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "web" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = merge(local.labels, { component = "web" })
    }

    template {
      metadata {
        labels      = merge(local.labels, { component = "web" })
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "web"
          image = var.web_image

          port {
            container_port = 80
          }

          env {
            name  = "APPFLOWY_BASE_URL"
            value = "https://${var.hostname}"
          }

          # Web frontend uses public gotrue URL
          env {
            name  = "APPFLOWY_GOTRUE_BASE_URL"
            value = "https://${var.hostname}/gotrue"
          }

          env {
            name  = "APPFLOWY_WS_BASE_URL"
            value = "wss://${var.hostname}/ws/v2"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "web" {
  metadata {
    name      = "appflowy-web"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "web" })
  }

  spec {
    selector = merge(local.labels, { component = "web" })

    port {
      port        = 80
      target_port = 80
    }
  }
}

# =============================================================================
# IngressRoute - Path-based routing with per-path middleware support
# =============================================================================
#
# Using Traefik IngressRoute CRD instead of Kubernetes Ingress for:
# - Per-path middleware support (strip prefix on /gotrue only)
# - CORS headers on gotrue
# - CSP headers on web

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "appflowy"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        # GoTrue - /gotrue/* with strip prefix and CORS
        {
          match = "Host(`${var.hostname}`) && PathPrefix(`/gotrue`)"
          kind  = "Rule"
          middlewares = [
            { name = "gotrue-strip-prefix", namespace = var.namespace },
            { name = "appflowy-headers", namespace = var.namespace }
          ]
          services = [
            {
              name = kubernetes_service.gotrue.metadata[0].name
              port = 9999
            }
          ]
        },
        # Cloud API - /api/*
        {
          match = "Host(`${var.hostname}`) && PathPrefix(`/api`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.cloud.metadata[0].name
              port = 8000
            }
          ]
        },
        # WebSocket - /ws/*
        {
          match = "Host(`${var.hostname}`) && PathPrefix(`/ws`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.cloud.metadata[0].name
              port = 8000
            }
          ]
        },
        # Web frontend - catch-all with CSP headers
        {
          match    = "Host(`${var.hostname}`)"
          kind     = "Rule"
          priority = 1
          middlewares = [
            { name = "appflowy-headers", namespace = var.namespace }
          ]
          services = [
            {
              name = kubernetes_service.web.metadata[0].name
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

# Traefik middleware for CORS headers on gotrue
resource "kubectl_manifest" "appflowy_headers_middleware" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "appflowy-headers"
      namespace = var.namespace
    }
    spec = {
      headers = {
        accessControlAllowOriginList = ["https://${var.hostname}"]
        accessControlAllowHeaders    = ["*"]
        contentSecurityPolicy        = "script-src * 'self' 'unsafe-eval' 'unsafe-inline'"
      }
    }
  })
}

# Traefik middleware for stripping /gotrue prefix
resource "kubectl_manifest" "gotrue_strip_prefix" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "gotrue-strip-prefix"
      namespace = var.namespace
    }
    spec = {
      stripPrefix = {
        prefixes = ["/gotrue"]
      }
    }
  })
}
