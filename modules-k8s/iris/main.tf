# Iris - Self-hosted media server (Movies & TV)
#
# Components:
#   iris    — Unified Go binary with embedded React SPA (port 8080)
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
  server_labels = merge(local.labels, { component = "server" })
  valkey_labels = merge(local.labels, { component = "valkey" })
}

# =============================================================================
# Image cache PVC  (seaweedfs, 10 Gi)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "image_cache" {
  metadata {
    name      = "iris-image-cache-sw"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "seaweedfs"
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
    mount_options                    = ["soft", "ro", "timeo=150", "retrans=3"]
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
# Iris Deployment + Service  (unified Go binary with embedded SPA)
# =============================================================================

resource "kubernetes_deployment" "iris" {
  metadata {
    name      = "iris"
    namespace = var.namespace
    labels    = local.server_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.server_labels
    }

    template {
      metadata {
        labels = local.server_labels
      }

      spec {
        image_pull_secrets {
          name = "gitlab-registry"
        }

        container {
          name              = "iris"
          image             = var.image
          image_pull_policy = "Always"

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
            name  = "AUTH_PROVIDERS"
            value = var.auth_providers
          }
          env {
            name  = "LOCAL_AUTH_SESSION_TTL_SECONDS"
            value = tostring(var.local_auth_session_ttl_seconds)
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
            name  = "OIDC_ADMIN_CLAIM"
            value = var.oidc_admin_claim
          }
          env {
            name  = "OIDC_ADMIN_VALUE"
            value = var.oidc_admin_value
          }
          env {
            name  = "OIDC_CLIENT_ID"
            value = var.oidc_client_id
          }
          env {
            name  = "OIDC_REDIRECT_URI"
            value = var.oidc_redirect_uri != "" ? var.oidc_redirect_uri : "https://${var.hostname}/"
          }
          env {
            name  = "OIDC_SILENT_REDIRECT_URI"
            value = var.oidc_silent_redirect_uri != "" ? var.oidc_silent_redirect_uri : "https://${var.hostname}/silent-renew.html"
          }
          env {
            name  = "OIDC_PROVIDER_NAME"
            value = var.oidc_provider_name
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
          env {
            name  = "DB_MAX_CONNS"
            value = tostring(var.db_max_conns)
          }
          env {
            name  = "MAX_CONCURRENT_SESSIONS"
            value = tostring(var.max_concurrent_sessions)
          }
          env {
            name  = "TRANSCODE_WORKERS"
            value = tostring(var.transcode_workers)
          }
          env {
            name  = "SCANNER_PARALLELISM"
            value = tostring(var.scanner_parallelism)
          }
          env {
            name  = "IMAGE_CACHE_MAX_SIZE"
            value = tostring(var.image_cache_max_size)
          }
          env {
            name  = "TRUSTED_PROXIES"
            value = var.trusted_proxies
          }
          env {
            name  = "APP_ORIGIN"
            value = var.app_origin != "" ? var.app_origin : "https://${var.hostname}"
          }

          env {
            name  = "PLEX_CLIENT_ID"
            value = var.plex_client_id
          }

          # Sensitive config from iris-secrets (plain Kubernetes Secret)
          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.iris.metadata[0].name
                key  = "SECRET_KEY"
              }
            }
          }
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
                name     = data.kubernetes_secret.iris.metadata[0].name
                key      = "TMDB_API_KEY"
                optional = true
              }
            }
          }
          env {
            name = "TVDB_API_KEY"
            value_from {
              secret_key_ref {
                name     = data.kubernetes_secret.iris.metadata[0].name
                key      = "TVDB_API_KEY"
                optional = true
              }
            }
          }
          env {
            name = "TRAKT_CLIENT_ID"
            value_from {
              secret_key_ref {
                name     = data.kubernetes_secret.iris.metadata[0].name
                key      = "TRAKT_CLIENT_ID"
                optional = true
              }
            }
          }
          env {
            name = "TRAKT_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name     = data.kubernetes_secret.iris.metadata[0].name
                key      = "TRAKT_CLIENT_SECRET"
                optional = true
              }
            }
          }

          volume_mount {
            name              = "image-cache"
            mount_path        = "/data/iris/images"
            mount_propagation = "HostToContainer"
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

          startup_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 10
            failure_threshold = 30
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

resource "kubernetes_service" "iris" {
  metadata {
    name      = "iris"
    namespace = var.namespace
    labels    = local.server_labels
  }

  spec {
    selector = local.server_labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# =============================================================================
# Ingress  (single hostname, all traffic to unified server)
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

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.iris.metadata[0].name
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
}
