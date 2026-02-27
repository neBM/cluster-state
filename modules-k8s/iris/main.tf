# Iris - Self-hosted media server (Movies & TV)
#
# Components:
#   api     — Go REST + WebSocket backend (port 8080)
#   web     — React SPA served by nginx (port 8080)
#   valkey  — In-cluster Redis-compatible cache (port 6379)
#
# External dependencies (must exist before apply):
#   PostgreSQL  — martinibar.lan:5433, database "iris", user "iris"
#   Vault       — nomad/default/iris (DATABASE_URL, TMDB_API_KEY, TVDB_API_KEY)
#   Keycloak    — prod realm, client "iris-api"
#   NFS media   — var.media_nfs_server:var.media_nfs_path, mounted read-only at /media

locals {
  app_name = "iris"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
  api_labels    = merge(local.labels, { component = "api" })
  web_labels    = merge(local.labels, { component = "web" })
  valkey_labels = merge(local.labels, { component = "valkey" })
}

# =============================================================================
# Image cache PVC  (glusterfs-nfs, 10 Gi)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "image_cache" {
  metadata {
    name      = "iris-image-cache"
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      # NFS provisioner uses this annotation to name the directory on the NFS server.
      "volume-name" = "iris_image_cache"
    }
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "glusterfs-nfs"
    resources {
      requests = { storage = "10Gi" }
    }
  }
}

# =============================================================================
# Synology NAS NFS PersistentVolume for media library (soft, read-only)
#
# Inline nfs{} volumes use kernel-default 'hard' mounts. If the NAS becomes
# unreachable, hard-mounted NFS kernel threads block indefinitely, starving
# the node's network stack. 'soft' returns EIO to the application instead.
# =============================================================================

resource "kubernetes_persistent_volume" "synology_media" {
  metadata {
    name = "iris-synology-media"
  }
  spec {
    capacity = {
      storage = "10Ti"
    }
    access_modes                     = ["ReadOnlyMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "synology-nfs-static"
    mount_options                    = ["soft", "ro"]
    persistent_volume_source {
      nfs {
        server    = var.media_nfs_server
        path      = var.media_nfs_path
        read_only = true
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "synology_media" {
  metadata {
    name      = "iris-synology-media"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    access_modes       = ["ReadOnlyMany"]
    storage_class_name = "synology-nfs-static"
    volume_name        = kubernetes_persistent_volume.synology_media.metadata[0].name
    resources {
      requests = {
        storage = "10Ti"
      }
    }
  }
}

# =============================================================================
# Valkey  (in-cluster Redis-compatible cache, no auth)
# =============================================================================

resource "kubernetes_deployment" "valkey" {
  metadata {
    name      = "iris-valkey"
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
          image = var.valkey_image

          port {
            name           = "valkey"
            container_port = 6379
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "valkey" {
  metadata {
    name      = "iris-valkey"
    namespace = var.namespace
    labels    = local.valkey_labels
  }

  spec {
    selector = local.valkey_labels
    port {
      name        = "valkey"
      port        = 6379
      target_port = 6379
    }
  }
}

# =============================================================================
# API Deployment + Service
# =============================================================================

resource "kubernetes_deployment" "api" {
  metadata {
    name      = "iris-api"
    namespace = var.namespace
    labels    = local.api_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.api_labels
    }

    template {
      metadata {
        labels = local.api_labels
      }

      spec {
        image_pull_secrets {
          name = "gitlab-registry"
        }

        container {
          name  = "api"
          image = var.api_image

          port {
            name           = "http"
            container_port = 8080
          }

          # Non-sensitive config set directly
          env {
            name  = "REDIS_URL"
            value = "redis://iris-valkey.${var.namespace}.svc.cluster.local:6379/0"
          }
          env {
            name  = "KEYCLOAK_ISSUER_URL"
            value = var.keycloak_issuer_url
          }
          env {
            name  = "KEYCLOAK_AUDIENCE"
            value = var.keycloak_audience
          }
          env {
            name  = "MEDIA_DIRS"
            value = var.media_dirs
          }
          env {
            name  = "IMAGE_CACHE_DIR"
            value = "/data/iris/images"
          }
          env {
            name  = "HLS_TMP_BASE_DIR"
            value = "/data/iris/hls-sessions"
          }

          # Sensitive config from ExternalSecret → iris-secrets
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.iris.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name = "TMDB_API_KEY"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.iris.metadata[0].name
                key  = "TMDB_API_KEY"
              }
            }
          }
          env {
            name = "TVDB_API_KEY"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.iris.metadata[0].name
                key  = "TVDB_API_KEY"
              }
            }
          }

          volume_mount {
            name       = "image-cache"
            mount_path = "/data/iris/images"
          }
          volume_mount {
            name       = "hls-tmp"
            mount_path = "/data/iris/hls-sessions"
          }
          volume_mount {
            name       = "media"
            mount_path = "/media"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "1Gi" }
          }
        }

        volume {
          name = "image-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.image_cache.metadata[0].name
          }
        }

        volume {
          name = "hls-tmp"
          empty_dir {}
        }

        # Media library — via PV with soft mount option (read-only)
        volume {
          name = "media"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.synology_media.metadata[0].name
            read_only  = true
          }
        }
      }
    }
  }

  # kubernetes_service.valkey is an implicit dependency via the REDIS_URL env var value.
  # data.kubernetes_secret.iris is an implicit dependency via secret_key_ref references above.
}

resource "kubernetes_service" "api" {
  metadata {
    name      = "iris-api"
    namespace = var.namespace
    labels    = local.api_labels
  }

  spec {
    selector = local.api_labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# =============================================================================
# Web Deployment + Service  (nginx serving SPA)
# =============================================================================

resource "kubernetes_deployment" "web" {
  metadata {
    name      = "iris-web"
    namespace = var.namespace
    labels    = local.web_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.web_labels
    }

    template {
      metadata {
        labels = local.web_labels
      }

      spec {
        image_pull_secrets {
          name = "gitlab-registry"
        }

        container {
          name  = "web"
          image = var.web_image

          port {
            name           = "http"
            container_port = 8080
          }

          # OIDC configuration for the SPA — injected into config.js at
          # container startup by docker-entrypoint.sh via envsubst.
          env {
            name  = "IRIS_OIDC_AUTHORITY"
            value = var.keycloak_issuer_url
          }
          env {
            name  = "IRIS_OIDC_CLIENT_ID"
            value = var.keycloak_audience
          }
          env {
            name  = "IRIS_OIDC_REDIRECT_URI"
            value = "https://${var.hostname}/callback"
          }
          env {
            name  = "IRIS_OIDC_SILENT_REDIRECT_URI"
            value = "https://${var.hostname}/silent-renew.html"
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "web" {
  metadata {
    name      = "iris-web"
    namespace = var.namespace
    labels    = local.web_labels
  }

  spec {
    selector = local.web_labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# =============================================================================
# Ingress  (single hostname, path-based routing via Traefik)
# =============================================================================

resource "kubernetes_ingress_v1" "iris" {
  metadata {
    name      = "iris"
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
      hosts       = [var.hostname]
      secret_name = "wildcard-brmartin-tls"
    }

    # Web SPA — catch-all, must be declared first so more-specific rules below take priority
    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.web.metadata[0].name
              port { number = 8080 }
            }
          }
        }
      }
    }

    # API and WebSocket routes — Traefik gives longer paths priority over /
    rule {
      host = var.hostname
      http {
        path {
          path      = "/api"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.api.metadata[0].name
              port { number = 8080 }
            }
          }
        }

        path {
          path      = "/ws"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.api.metadata[0].name
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
}
