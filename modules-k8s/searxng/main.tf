locals {
  app_name = "searxng"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

resource "kubernetes_deployment" "searxng" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = local.app_name
          image = "docker.io/searxng/searxng:${var.image_tag}"

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "SEARXNG_BASE_URL"
            value = "https://${var.hostname}"
          }

          env {
            name  = "SEARXNG_VALKEY_URL"
            value = var.valkey_url
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/searxng"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/searxng"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "120Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config"
          host_path {
            path = "/storage/v/glusterfs_searxng_config"
            type = "Directory"
          }
        }

        volume {
          name = "cache"
          empty_dir {
            size_limit = "100Mi"
          }
        }

        # Multi-arch support - GlusterFS NFS mount available on all nodes
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64", "arm64"]
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "searxng" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "searxng" {
  metadata {
    name      = local.app_name
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
              name = kubernetes_service.searxng.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
