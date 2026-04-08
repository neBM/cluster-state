# -----------------------------------------------------------------------------
# Volume Server — DaemonSet on storage nodes only
# -----------------------------------------------------------------------------

resource "kubernetes_service" "volume" {
  metadata {
    name      = "seaweedfs-volume"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "volume" })
  }

  spec {
    selector = { app = local.app_name, component = "volume" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }

    port {
      name        = "grpc"
      port        = 18080
      target_port = 18080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_daemon_set_v1" "volume" {
  metadata {
    name      = "seaweedfs-volume"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "volume" })
  }

  spec {
    selector {
      match_labels = { app = local.app_name, component = "volume" }
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "volume" })
      }

      spec {
        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = var.volume_node_hostnames
                }
              }
            }
          }
        }

        container {
          name  = "volume"
          image = "chrislusf/seaweedfs:${var.seaweedfs_image_tag}"

          command = ["sh", "-c"]
          args = [
            "weed volume -dir=/data -max=0 -mserver=seaweedfs-master:9333 -port=8080 -port.grpc=18080 -dataCenter=${var.data_center} -rack=$NODE_NAME -ip=$POD_IP"
          ]

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }

          port {
            name           = "http"
            container_port = 8080
          }

          port {
            name           = "grpc"
            container_port = 18080
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            http_get {
              path = "/status"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/status"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "data"
          host_path {
            path = var.volume_data_path
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}
