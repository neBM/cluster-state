locals {
  app_name  = "pi5-macb-offload-fix"
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "node-tuning"
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
    "disable-offloads.sh" = file("${path.module}/scripts/disable-offloads.sh")
  }
}

# DaemonSet runs only on arm64 nodes (Heracles and Nyx — both Raspberry Pi 5).
# Mitigates LP#2133877: macb driver TX descriptor ring wedges across the RP1
# PCIe link when TSO is used with scatter-gather. Disabling both offloads via
# `ethtool -K eth0 tso off sg off` avoids the stall path. Remove this module
# when an upstream macb fix lands and nodes are upgraded past the affected
# 6.17.0-1004/1006-raspi kernel series.
#
# Uses nsenter to run the host's ethtool binary in the host's network
# namespace — same pattern as rpi-throttle-monitor's vcgencmd invocation.
resource "kubernetes_daemonset" "offload_fix" {
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

        # Restrict to arm64 nodes only (Raspberry Pi 5). Hestia is amd64
        # and uses a different NIC/driver, unaffected by LP#2133877.
        node_selector = {
          "kubernetes.io/arch" = "arm64"
        }

        container {
          name    = "offload-fix"
          image   = "${var.image}:${var.image_tag}"
          command = ["/bin/bash", "/scripts/disable-offloads.sh"]

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
