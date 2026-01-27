# Nextcloud - File storage and collaboration platform
#
# Components:
# - nextcloud: Main app with redis sidecar (port 80)
# - cron: Background jobs container (shares volumes with nextcloud)
# - collabora: Document editor (port 9980)
#
# Storage:
# - config: /storage/v/glusterfs_nextcloud_config
# - custom_apps: /storage/v/glusterfs_nextcloud_custom_apps
# - data: /storage/v/glusterfs_nextcloud_data
#
# External PostgreSQL on martinibar.lan:5433

locals {
  nextcloud_labels = {
    app       = "nextcloud"
    component = "nextcloud"
  }
  collabora_labels = {
    app       = "nextcloud"
    component = "collabora"
  }

  # Elastic Agent log routing annotations
  # Routes logs to logs-kubernetes.container_logs.nextcloud-* index
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.nextcloud"
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
      type = "Recreate" # Required for hostPath with single-writer volumes
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
        # GlusterFS NFS mounts (/storage/v/) are available on all nodes

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
          host_path {
            path = var.config_path
            type = "Directory"
          }
        }

        volume {
          name = "custom-apps"
          host_path {
            path = var.custom_apps_path
            type = "Directory"
          }
        }

        volume {
          name = "data"
          host_path {
            path = var.data_path
            type = "Directory"
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
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
# Collabora Deployment (document editor)
# =============================================================================

resource "kubernetes_deployment" "collabora" {
  metadata {
    name      = "collabora"
    namespace = var.namespace
    labels    = local.collabora_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.collabora_labels
    }

    template {
      metadata {
        labels      = local.collabora_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "collabora"
          image = "${var.collabora_image}:${var.collabora_tag}"

          port {
            container_port = 9980
          }

          env {
            name  = "aliasgroup1"
            value = "https://${var.hostname}:443"
          }

          env {
            name  = "username"
            value = "admin"
          }

          env {
            name = "password"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "collabora_password"
              }
            }
          }

          env {
            name  = "extra_params"
            value = "--o:ssl.enable=false --o:ssl.termination=true"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "768Mi"
            }
            limits = {
              memory = "1024Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 9980
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 9980
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

resource "kubernetes_service" "collabora" {
  metadata {
    name      = "collabora"
    namespace = var.namespace
    labels    = local.collabora_labels
  }

  spec {
    selector = local.collabora_labels

    port {
      port        = 9980
      target_port = 9980
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
        # Nextcloud main route with WebDAV redirect
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

# Collabora IngressRoute (separate hostname)
resource "kubectl_manifest" "collabora_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "collabora"
      namespace = var.namespace
      labels    = { app = "nextcloud", component = "collabora" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.collabora_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.collabora.metadata[0].name
              port = 9980
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
