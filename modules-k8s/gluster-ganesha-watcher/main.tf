locals {
  app_name  = "gluster-ganesha-watcher"
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "infrastructure"
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
    "watch-reconnect.sh" = file("${path.module}/scripts/watch-reconnect.sh")
  }
}

# DaemonSet runs on all three nodes (Hestia, Heracles, Nyx).
# Each pod restarts its own node's NFS-Ganesha when a GlusterFS brick reconnects,
# resetting the stale libgfapi connection that causes NFS4ERR_IO.
resource "kubernetes_daemonset" "watcher" {
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
        host_pid     = true
        host_network = true

        container {
          name    = "watcher"
          image   = "${var.image}:${var.image_tag}"
          command = ["/bin/bash", "/scripts/watch-reconnect.sh"]

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
            name       = "glusterfs-log"
            mount_path = "/host/var/log/glusterfs"
            read_only  = true
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
        }

        volume {
          name = "glusterfs-log"
          host_path {
            path = "/var/log/glusterfs"
            type = "Directory"
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.scripts.metadata[0].name
            default_mode = "0755"
          }
        }

        # Tolerate all taints so the pod runs on every node regardless of role
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
