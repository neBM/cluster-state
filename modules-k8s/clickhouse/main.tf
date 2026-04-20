locals {
  app_name = "clickhouse"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "clickhouse_data" {
  metadata {
    name      = "clickhouse-data-sw"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "clickhouse" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = "clickhouse"
          image = "clickhouse/clickhouse-server:${var.image_tag}"

          port {
            container_port = 8123
            name           = "http"
          }

          port {
            container_port = 9000
            name           = "native"
          }

          env {
            name  = "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT"
            value = "1"
          }

          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "clickhouse-secrets"
                key  = "CLICKHOUSE_PASSWORD"
              }
            }
          }

          liveness_probe {
            http_get {
              path   = "/ping"
              port   = 8123
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path   = "/ping"
              port   = 8123
              scheme = "HTTP"
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "clickhouse-data"
            mount_path = "/var/lib/clickhouse"
          }
        }

        volume {
          name = "clickhouse-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.clickhouse_data.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.clickhouse_data]
}

resource "kubernetes_service_v1" "clickhouse" {
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
      name       = "http"
      port       = 8123
      target_port = 8123
      protocol   = "TCP"
    }

    port {
      name       = "native"
      port       = 9000
      target_port = 9000
      protocol   = "TCP"
    }

    type = "ClusterIP"
  }
}
