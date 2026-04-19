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
#
# Uses kubectl_manifest so the pod spec can include DRA resourceClaims —
# the hashicorp/kubernetes provider does not support this field.
# =============================================================================

resource "kubectl_manifest" "iris_transcode_claim_template" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1"
    kind       = "ResourceClaimTemplate"
    metadata = {
      name      = "iris-transcode-hw"
      namespace = var.namespace
    }
    spec = {
      spec = {
        devices = {
          requests = [{ name = "transcode", exactly = { deviceClassName = "iris-transcode-hw" } }]
        }
      }
    }
  })
}

resource "kubectl_manifest" "iris" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "iris"
      namespace = var.namespace
      labels    = local.server_labels
    }
    spec = {
      replicas = 1
      selector = { matchLabels = local.server_labels }
      template = {
        metadata = { labels = local.server_labels }
        spec = {
          imagePullSecrets = [{ name = "gitlab-registry" }]
          resourceClaims = [{
            name                      = "transcode"
            resourceClaimTemplateName = "iris-transcode-hw"
          }]
          containers = [{
            name            = "iris"
            image           = var.image
            imagePullPolicy = "Always"
            ports           = [{ name = "http", containerPort = 8080 }]
            env = [
              { name = "REDIS_URL", value = "redis://iris-valkey.${var.namespace}.svc.cluster.local:6379/0" },
              { name = "AUTH_PROVIDERS", value = var.auth_providers },
              { name = "LOCAL_AUTH_SESSION_TTL_SECONDS", value = tostring(var.local_auth_session_ttl_seconds) },
              { name = "KEYCLOAK_ISSUER_URL", value = var.keycloak_issuer_url },
              { name = "KEYCLOAK_AUDIENCE", value = var.keycloak_audience },
              { name = "OIDC_ADMIN_CLAIM", value = var.oidc_admin_claim },
              { name = "OIDC_ADMIN_VALUE", value = var.oidc_admin_value },
              { name = "OIDC_CLIENT_ID", value = var.oidc_client_id },
              { name = "OIDC_REDIRECT_URI", value = var.oidc_redirect_uri != "" ? var.oidc_redirect_uri : "https://${var.hostname}/" },
              { name = "OIDC_SILENT_REDIRECT_URI", value = var.oidc_silent_redirect_uri != "" ? var.oidc_silent_redirect_uri : "https://${var.hostname}/silent-renew.html" },
              { name = "OIDC_PROVIDER_NAME", value = var.oidc_provider_name },
              { name = "MEDIA_DIRS", value = var.media_dirs },
              { name = "IMAGE_CACHE_DIR", value = "/data/iris/images" },
              { name = "HLS_TMP_BASE_DIR", value = "/data/iris/hls-sessions" },
              { name = "DB_MAX_CONNS", value = tostring(var.db_max_conns) },
              { name = "MAX_CONCURRENT_SESSIONS", value = tostring(var.max_concurrent_sessions) },
              { name = "TRANSCODE_WORKERS", value = tostring(var.transcode_workers) },
              { name = "SCANNER_PARALLELISM", value = tostring(var.scanner_parallelism) },
              { name = "IMAGE_CACHE_MAX_SIZE", value = tostring(var.image_cache_max_size) },
              { name = "TRUSTED_PROXIES", value = var.trusted_proxies },
              { name = "APP_ORIGIN", value = var.app_origin != "" ? var.app_origin : "https://${var.hostname}" },
              { name = "PLEX_CLIENT_ID", value = var.plex_client_id },
              { name = "SECRET_KEY", valueFrom = { secretKeyRef = { name = data.kubernetes_secret.iris.metadata[0].name, key = "SECRET_KEY" } } },
              { name = "DATABASE_URL", valueFrom = { secretKeyRef = { name = data.kubernetes_secret.iris.metadata[0].name, key = "DATABASE_URL" } } },
              { name = "TMDB_API_KEY", valueFrom = { secretKeyRef = { name = data.kubernetes_secret.iris.metadata[0].name, key = "TMDB_API_KEY", optional = true } } },
              { name = "TVDB_API_KEY", valueFrom = { secretKeyRef = { name = data.kubernetes_secret.iris.metadata[0].name, key = "TVDB_API_KEY", optional = true } } },
              { name = "TRAKT_CLIENT_ID", valueFrom = { secretKeyRef = { name = data.kubernetes_secret.iris.metadata[0].name, key = "TRAKT_CLIENT_ID", optional = true } } },
              { name = "TRAKT_CLIENT_SECRET", valueFrom = { secretKeyRef = { name = data.kubernetes_secret.iris.metadata[0].name, key = "TRAKT_CLIENT_SECRET", optional = true } } },
            ]
            resources = {
              requests = { cpu = "100m", memory = "256Mi" }
              limits   = { memory = "1Gi" }
              claims   = [{ name = "transcode" }]
            }
            volumeMounts = [
              { name = "image-cache", mountPath = "/data/iris/images", mountPropagation = "HostToContainer" },
              { name = "hls-tmp", mountPath = "/data/iris/hls-sessions" },
              { name = "media", mountPath = "/media", readOnly = true },
            ]
            startupProbe = {
              httpGet          = { path = "/healthz", port = 8080 }
              periodSeconds    = 10
              failureThreshold = 30
            }
            livenessProbe = {
              httpGet             = { path = "/healthz", port = 8080 }
              initialDelaySeconds = 10
              periodSeconds       = 10
            }
            readinessProbe = {
              httpGet             = { path = "/healthz", port = 8080 }
              initialDelaySeconds = 5
              periodSeconds       = 10
            }
          }]
          volumes = [
            { name = "image-cache", persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.image_cache.metadata[0].name } },
            { name = "hls-tmp", emptyDir = {} },
            { name = "media", persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.synology_media.metadata[0].name, readOnly = true } },
          ]
        }
      }
    }
  })

  depends_on = [
    kubectl_manifest.iris_transcode_claim_template,
    kubernetes_service.valkey,
  ]
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
