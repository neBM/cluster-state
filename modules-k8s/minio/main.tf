locals {
  app_name = "minio"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

# Deployment for MinIO
resource "kubernetes_deployment" "minio" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate" # MinIO requires exclusive access to data directory
    }

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
        # Main MinIO container
        container {
          name  = local.app_name
          image = "quay.io/minio/minio:${var.image_tag}"

          args = ["server", "/data", "--console-address", ":9001"]

          port {
            container_port = 9000
            name           = "s3"
          }

          port {
            container_port = 9001
            name           = "console"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          env_from {
            secret_ref {
              name = "${local.app_name}-secrets"
            }
          }

          env {
            name  = "MINIO_BROWSER_REDIRECT_URL"
            value = "https://${var.console_hostname}"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/minio/health/live"
              port = 9000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/minio/health/ready"
              port = 9000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Data volume from GlusterFS via hostPath
        volume {
          name = "data"
          host_path {
            path = var.data_path
            type = "Directory"
          }
        }

        # GlusterFS NFS mounts (/storage/v/) are available on all nodes
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

# Service for S3 API - NodePort so Nomad services can reach it
resource "kubernetes_service" "minio_api" {
  metadata {
    name      = "${local.app_name}-api"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 9000
      target_port = 9000
      node_port   = 30900 # Fixed NodePort for predictable endpoint
      protocol    = "TCP"
      name        = "s3"
    }

    type = "NodePort"
  }
}

# Service for Console - ClusterIP (external access via Traefik)
resource "kubernetes_service" "minio_console" {
  metadata {
    name      = "${local.app_name}-console"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 9001
      target_port = 9001
      protocol    = "TCP"
      name        = "console"
    }

    type = "ClusterIP"
  }
}

# Ingress for Console (web UI)
resource "kubernetes_ingress_v1" "minio_console" {
  metadata {
    name      = "${local.app_name}-console"
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
      hosts       = [var.console_hostname]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = var.console_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.minio_console.metadata[0].name
              port {
                number = 9001
              }
            }
          }
        }
      }
    }
  }
}
