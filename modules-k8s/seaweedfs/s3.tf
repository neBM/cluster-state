# -----------------------------------------------------------------------------
# S3 Gateway — stateless proxy to filer
# -----------------------------------------------------------------------------

# S3 identities are configured via `weed shell → s3.configure` and persisted
# in filer metadata. No local config file needed — the S3 gateway reads
# identities from the filer automatically. See secrets.tf for setup instructions.

resource "kubernetes_service" "s3" {
  metadata {
    name      = "seaweedfs-s3"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "s3" })
  }

  spec {
    selector = { app = local.app_name, component = "s3" }

    port {
      name        = "http"
      port        = 8333
      target_port = 8333
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "s3" {
  metadata {
    name      = "seaweedfs-s3"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "s3" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = local.app_name, component = "s3" }
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "s3" })
      }

      spec {
        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "s3"
          image = "chrislusf/seaweedfs:${var.seaweedfs_image_tag}"

          args = [
            "s3",
            "-filer=seaweedfs-filer:8888",
            "-port=8333",
          ]

          port {
            name           = "http"
            container_port = 8333
          }

          readiness_probe {
            tcp_socket {
              port = 8333
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }

          liveness_probe {
            tcp_socket {
              port = 8333
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }

      }
    }
  }
}
