# Langfuse - LLM observability platform
#
# Components:
# - langfuse-web: Next.js web application (port 3000)
# - langfuse-worker: Background event processing worker
#
# External PostgreSQL on martinibar (192.168.1.10:5433)
# ClickHouse for analytics storage
# Valkey (Redis-compatible) for queuing
# SeaweedFS S3 for event blob storage
# OAuth via Keycloak

locals {
  web_labels = {
    app        = "langfuse"
    component  = "web"
    managed-by = "terraform"
  }

  worker_labels = {
    app        = "langfuse"
    component  = "worker"
    managed-by = "terraform"
  }

  common_env = [
    {
      name  = "NEXTAUTH_URL"
      value = "https://${var.hostname}"
    },
    {
      name  = "TELEMETRY_ENABLED"
      value = "false"
    },
    {
      name  = "CLICKHOUSE_MIGRATION_URL"
      value = "clickhouse://clickhouse.default.svc.cluster.local:9000"
    },
    {
      name  = "CLICKHOUSE_URL"
      value = "http://clickhouse.default.svc.cluster.local:8123"
    },
    {
      name  = "CLICKHOUSE_USER"
      value = "default"
    },
    {
      name  = "REDIS_CONNECTION_STRING"
      value = "redis://valkey.default.svc.cluster.local:6379/0"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_ENABLED"
      value = "true"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_BUCKET"
      value = "langfuse"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT"
      value = "http://seaweedfs-s3.default.svc.cluster.local:8333"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_REGION"
      value = "us-east-1"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE"
      value = "true"
    },
    {
      name  = "AUTH_KEYCLOAK_ISSUER"
      value = "https://sso.brmartin.co.uk/realms/prod"
    },
  ]

  secret_env = [
    {
      name       = "DATABASE_URL"
      secret_key = "DATABASE_URL"
    },
    {
      # DIRECT_URL = same as DATABASE_URL; Prisma uses it for migrations (no pooler in this setup)
      name       = "DIRECT_URL"
      secret_key = "DATABASE_URL"
    },
    {
      name       = "NEXTAUTH_SECRET"
      secret_key = "NEXTAUTH_SECRET"
    },
    {
      name       = "SALT"
      secret_key = "SALT"
    },
    {
      name       = "ENCRYPTION_KEY"
      secret_key = "ENCRYPTION_KEY"
    },
    {
      name       = "CLICKHOUSE_PASSWORD"
      secret_key = "CLICKHOUSE_PASSWORD"
    },
    {
      name       = "LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID"
      secret_key = "S3_ACCESS_KEY_ID"
    },
    {
      name       = "LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY"
      secret_key = "S3_SECRET_ACCESS_KEY"
    },
    {
      name       = "AUTH_KEYCLOAK_CLIENT_ID"
      secret_key = "AUTH_CUSTOM_CLIENT_ID"
    },
    {
      name       = "AUTH_KEYCLOAK_CLIENT_SECRET"
      secret_key = "AUTH_CUSTOM_CLIENT_SECRET"
    },
  ]
}

# =============================================================================
# Web Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "web" {
  metadata {
    name      = "langfuse-web"
    namespace = var.namespace
    labels    = local.web_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.web_labels
    }

    template {
      metadata {
        labels = local.web_labels
      }

      spec {
        container {
          name  = "langfuse-web"
          image = "langfuse/langfuse:${var.image_tag}"

          port {
            container_port = 3000
          }

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          dynamic "env" {
            for_each = local.secret_env
            content {
              name = env.value.name
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = env.value.secret_key
                }
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/api/public/health"
              port = 3000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/api/public/health"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 10
          }
        }
      }
    }
  }
}

# =============================================================================
# Worker Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "worker" {
  metadata {
    name      = "langfuse-worker"
    namespace = var.namespace
    labels    = local.worker_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.worker_labels
    }

    template {
      metadata {
        labels = local.worker_labels
      }

      spec {
        container {
          name  = "langfuse-worker"
          image = "langfuse/langfuse-worker:${var.image_tag}"

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          dynamic "env" {
            for_each = local.secret_env
            content {
              name = env.value.name
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = env.value.secret_key
                }
              }
            }
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
}

# =============================================================================
# Service and IngressRoute
# =============================================================================

resource "kubernetes_service_v1" "web" {
  metadata {
    name      = "langfuse-web"
    namespace = var.namespace
    labels    = local.web_labels
  }

  spec {
    selector = local.web_labels

    port {
      port        = 80
      target_port = 3000
    }
  }
}

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "langfuse"
      namespace = var.namespace
      labels    = local.web_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service_v1.web.metadata[0].name
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

# Langfuse secrets are managed outside Terraform as a plain Kubernetes Secret.
# Secret name: langfuse-secrets
# Keys: DATABASE_URL, NEXTAUTH_SECRET, SALT, ENCRYPTION_KEY, CLICKHOUSE_PASSWORD,
#       S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, AUTH_CUSTOM_CLIENT_ID, AUTH_CUSTOM_CLIENT_SECRET
