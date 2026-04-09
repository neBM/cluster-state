# -----------------------------------------------------------------------------
# SeaweedFS Consumer Recycler — DaemonSet
#
# Per-node reconciler that cycles consumer pods when seaweedfs-mount restarts
# or a FUSE mount goes bad. See:
#   docs/superpowers/specs/2026-04-08-seaweedfs-consumer-recycler-design.md
# -----------------------------------------------------------------------------

resource "kubernetes_service_account" "consumer_recycler" {
  metadata {
    name      = "seaweedfs-consumer-recycler"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "consumer-recycler" })
  }
}

resource "kubernetes_cluster_role" "consumer_recycler" {
  metadata {
    name   = "seaweedfs-consumer-recycler"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "consumer_recycler" {
  metadata {
    name   = "seaweedfs-consumer-recycler"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.consumer_recycler.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.consumer_recycler.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_daemon_set_v1" "consumer_recycler" {
  metadata {
    name      = "seaweedfs-consumer-recycler"
    namespace = var.namespace
    labels = merge(local.labels, {
      component                = "consumer-recycler"
      "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
    })
  }

  spec {
    selector {
      match_labels = {
        app                      = local.app_name
        "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
      }
    }

    template {
      metadata {
        labels = merge(local.labels, {
          "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
          component                = "consumer-recycler"
        })
      }

      spec {
        service_account_name = kubernetes_service_account.consumer_recycler.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name              = "recycler"
          image             = "registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:${var.consumer_recycler_image_tag}"
          image_pull_policy = "IfNotPresent"

          args = [
            "--metrics-bind-address=:9090",
            "--health-probe-bind-address=:9808",
            "--proc-root=/host/proc",
            "--stat-path=/usr/bin/stat",
          ]

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 9090
          }

          port {
            name           = "healthz"
            container_port = 9808
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "healthz"
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = "healthz"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "host-proc"
            mount_path = "/host/proc"
            read_only  = true
          }

          volume_mount {
            name       = "kubelet-pods"
            mount_path = "/var/lib/kubelet/pods"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "host-proc"
          host_path {
            path = "/proc"
            type = "Directory"
          }
        }

        volume {
          name = "kubelet-pods"
          host_path {
            path = "/var/lib/kubelet/pods"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "consumer_recycler_metrics" {
  metadata {
    name      = "seaweedfs-consumer-recycler-metrics"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "consumer-recycler" })
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9090"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    cluster_ip = "None" # headless — per-pod scraping
    selector = {
      app                      = local.app_name
      "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = "metrics"
    }
  }
}
