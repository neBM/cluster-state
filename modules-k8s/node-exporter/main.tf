locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "monitoring"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# DaemonSet to run on all nodes
resource "kubernetes_daemonset" "node_exporter" {
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
        labels = merge(local.labels, {
          "app.kubernetes.io/version" = var.image_tag
        })
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9100"
        }
      }

      spec {
        host_network = true
        host_pid     = true

        container {
          name  = local.app_name
          image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

          args = [
            "--path.procfs=/host/proc",
            "--path.sysfs=/host/sys",
            "--path.rootfs=/host/root",
            "--web.listen-address=:9100",
            "--collector.filesystem.ignored-mount-points=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/pods/.+)($|/)"
          ]

          port {
            name           = "metrics"
            container_port = 9100
            protocol       = "TCP"
            host_port      = 9100
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          volume_mount {
            name       = "proc"
            mount_path = "/host/proc"
            read_only  = true
          }

          volume_mount {
            name       = "sys"
            mount_path = "/host/sys"
            read_only  = true
          }

          volume_mount {
            name              = "root"
            mount_path        = "/host/root"
            read_only         = true
            mount_propagation = "HostToContainer"
          }
        }

        volume {
          name = "proc"
          host_path {
            path = "/proc"
          }
        }

        volume {
          name = "sys"
          host_path {
            path = "/sys"
          }
        }

        volume {
          name = "root"
          host_path {
            path = "/"
          }
        }

        toleration {
          effect   = "NoSchedule"
          operator = "Exists"
        }
      }
    }
  }
}

# Service for discovery
resource "kubernetes_service" "node_exporter" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9100"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "metrics"
      port        = 9100
      target_port = "metrics"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}