# Nextcloud - File storage platform
#
# Components:
# - nextcloud: Main app with redis sidecar (port 80)
# - cron: Background jobs container (shares volumes with nextcloud)
#
# Storage (PVCs via glusterfs-nfs StorageClass):
# - config: nextcloud_config -> /storage/v/glusterfs_nextcloud_config
# - custom_apps: nextcloud_custom_apps -> /storage/v/glusterfs_nextcloud_custom_apps
# - data: nextcloud_data -> /storage/v/glusterfs_nextcloud_data
#
# External PostgreSQL on 192.168.1.10:5433

locals {
  nextcloud_labels = {
    app       = "nextcloud"
    component = "nextcloud"
  }

  # Elastic Agent log routing annotations
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.nextcloud"
  }
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "config" {
  metadata {
    name      = "nextcloud-config"
    namespace = var.namespace
    annotations = {
      "volume-name" = "nextcloud_config"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "custom_apps" {
  metadata {
    name      = "nextcloud-custom-apps"
    namespace = var.namespace
    annotations = {
      "volume-name" = "nextcloud_custom_apps"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "nextcloud-data"
    namespace = var.namespace
    annotations = {
      "volume-name" = "nextcloud_data"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

# =============================================================================
# Nextcloud Deployment (with Redis sidecar)
# =============================================================================

resource "kubernetes_deployment" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = var.namespace
    labels    = local.nextcloud_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # Required for RWX volumes with single-writer semantics
    }

    selector {
      match_labels = local.nextcloud_labels
    }

    template {
      metadata {
        labels      = local.nextcloud_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # PVCs provisioned via glusterfs-nfs StorageClass (NFS-backed, available on all nodes)

        # Redis sidecar for caching and file locking
        container {
          name  = "redis"
          image = "${var.redis_image}:${var.redis_tag}"
          args  = ["--save", ""] # Disable persistence, ephemeral cache only

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
        }

        # Main Nextcloud container
        container {
          name  = "nextcloud"
          image = "${var.nextcloud_image}:${var.nextcloud_tag}"

          port {
            container_port = 80
          }

          env {
            name  = "POSTGRES_HOST"
            value = "${var.db_host}:${var.db_port}"
          }

          env {
            name  = "POSTGRES_DB"
            value = var.db_name
          }

          env {
            name  = "POSTGRES_USER"
            value = var.db_user
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "db_password"
              }
            }
          }

          env {
            name  = "NEXTCLOUD_TRUSTED_DOMAINS"
            value = var.hostname
          }

          env {
            name  = "OVERWRITEPROTOCOL"
            value = "https"
          }

          env {
            name  = "TRUSTED_PROXIES"
            value = "172.26.0.0/16 10.0.0.0/8"
          }

          env {
            name  = "REDIS_HOST"
            value = "127.0.0.1" # Redis sidecar in same pod
          }

          volume_mount {
            name       = "config"
            mount_path = "/var/www/html/config"
          }

          volume_mount {
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/html/data"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "1024Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = var.hostname
              }
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = var.hostname
              }
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Cron container for background jobs
        container {
          name    = "cron"
          image   = "${var.nextcloud_image}:${var.nextcloud_tag}"
          command = ["/cron.sh"]

          env {
            name  = "REDIS_HOST"
            value = "127.0.0.1"
          }

          volume_mount {
            name       = "config"
            mount_path = "/var/www/html/config"
          }

          volume_mount {
            name       = "custom-apps"
            mount_path = "/var/www/html/custom_apps"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/html/data"
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
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.config.metadata[0].name
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.custom_apps.metadata[0].name
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
    kubernetes_persistent_volume_claim.config,
    kubernetes_persistent_volume_claim.custom_apps,
    kubernetes_persistent_volume_claim.data,
  ]
}

resource "kubernetes_service" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = var.namespace
    labels    = local.nextcloud_labels
  }

  spec {
    selector = local.nextcloud_labels

    port {
      port        = 80
      target_port = 80
    }
  }
}

# =============================================================================
# IngressRoute for path-based routing with WebDAV redirect middleware
# =============================================================================

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "nextcloud"
      namespace = var.namespace
      labels    = { app = "nextcloud" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.hostname}`)"
          kind  = "Rule"
          middlewares = [
            { name = "nextcloud-webdav-redirect", namespace = var.namespace }
          ]
          services = [
            {
              name = kubernetes_service.nextcloud.metadata[0].name
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

# WebDAV redirect middleware for CalDAV/CardDAV clients
resource "kubectl_manifest" "webdav_redirect" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "nextcloud-webdav-redirect"
      namespace = var.namespace
    }
    spec = {
      redirectRegex = {
        regex       = "https://(.*)/.well-known/(?:card|cal)dav"
        replacement = "https://$1/remote.php/dav"
        permanent   = true
      }
    }
  })
}
