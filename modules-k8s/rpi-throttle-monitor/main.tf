locals {
  app_name  = "rpi-throttle-monitor"
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "monitoring"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

resource "kubernetes_config_map" "scripts" {
  metadata {
    name      = "${local.app_name}-scripts"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "monitor-throttle.sh" = file("${path.module}/scripts/monitor-throttle.sh")
  }
}

# DaemonSet runs only on arm64 nodes (Heracles and Nyx — both Raspberry Pi 5).
# Hestia is amd64 and has no VideoCore firmware, so vcgencmd is not available there.
resource "kubernetes_daemonset" "monitor" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = local.app_name
        "app.kubernetes.io/instance" = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        host_pid = true

        # Restrict to arm64 nodes only (Raspberry Pi 5)
        node_selector = {
          "kubernetes.io/arch" = "arm64"
        }

        container {
          name    = "monitor"
          image   = "${var.image}:${var.image_tag}"
          command = ["/bin/bash", "/scripts/monitor-throttle.sh"]

          security_context {
            privileged = true
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.scripts.metadata[0].name
            default_mode = "0755"
          }
        }

        toleration {
          effect   = "NoSchedule"
          operator = "Exists"
        }

        toleration {
          effect   = "NoExecute"
          operator = "Exists"
        }
      }
    }
  }
}
