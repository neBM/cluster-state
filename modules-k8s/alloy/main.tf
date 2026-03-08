locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "logging"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# ServiceAccount for Alloy
resource "kubernetes_service_account" "alloy" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }
}

# ClusterRole: Alloy needs to discover pods/nodes via K8s API
resource "kubernetes_cluster_role" "alloy" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "pods", "services", "endpoints", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes/proxy"]
    verbs      = ["get"]
  }
}

# ClusterRoleBinding: bind ClusterRole to ServiceAccount
resource "kubernetes_cluster_role_binding" "alloy" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.alloy.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.alloy.metadata[0].name
    namespace = local.namespace
  }
}

# ConfigMap: Alloy pipeline configuration
resource "kubernetes_config_map" "alloy_config" {
  metadata {
    name      = "${local.app_name}-config"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "config.alloy" = <<-ALLOY
      // =========================================================================
      // Pod log collection — tails /var/log/pods on the local node
      // =========================================================================

      discovery.kubernetes "pods" {
        role = "pod"
        selectors {
          role  = "pod"
          field = "spec.nodeName=" + env("NODE_NAME")
        }
      }

      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets

        // Keep only pods that have log files on disk
        rule {
          source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
          separator     = "/"
          target_label  = "__path__"
          replacement   = "/var/log/pods/*$1/*.log"
        }

        // Extract namespace label
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }

        // Extract pod label
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }

        // Extract container label
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }

        // Node label from env var (set in DaemonSet)
        rule {
          target_label = "node"
          replacement  = env("NODE_NAME")
        }

        // Set job label
        rule {
          target_label = "job"
          replacement  = "kubernetes/pods"
        }

        // Drop high-cardinality metadata
        rule {
          regex  = "__meta_kubernetes_pod_uid|__meta_kubernetes_pod_ip|__meta_kubernetes_host_ip"
          action = "labeldrop"
        }
      }

      local.file_match "pod_logs" {
        path_targets = discovery.relabel.pod_logs.output
      }

      loki.source.file "pod_logs" {
        targets    = local.file_match.pod_logs.targets
        forward_to = [loki.process.pod_logs.receiver]
      }

      loki.process "pod_logs" {
        // Parse CRI log format (containerd/K3s): timestamp stream flags message
        stage.cri {}

        // Drop kube-probe noise (liveness/readiness probe user-agent)
        stage.drop {
          expression = ".*kube-probe.*"
        }

        // Drop health check log noise
        stage.drop {
          expression = ".*(GET|HEAD) /health.* 200"
        }

          // Add cluster label
          stage.static_labels {
            values = {
              cluster = "k3s-homelab",
            }
          }

        forward_to = [loki.write.loki.receiver]
      }

      // =========================================================================
      // Host log collection — systemd journal
      // =========================================================================

      loki.source.journal "journal" {
        path          = "/var/log/journal"
        relabel_rules = discovery.relabel.journal_labels.rules
        forward_to    = [loki.write.loki.receiver]
        labels = {
          job     = "journal",
          node    = env("NODE_NAME"),
          cluster = "k3s-homelab",
        }
      }

      discovery.relabel "journal_labels" {
        targets = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }

        rule {
          source_labels = ["__journal_priority_keyword"]
          target_label  = "level"
        }
      }

      // =========================================================================
      // Host log collection — syslog and auth.log
      // =========================================================================

      local.file_match "host_logs" {
        path_targets = [
          {
            __path__ = "/var/log/syslog",
            job      = "node/syslog",
            node     = env("NODE_NAME"),
            cluster  = "k3s-homelab",
          },
          {
            __path__ = "/var/log/auth.log",
            job      = "node/auth",
            node     = env("NODE_NAME"),
            cluster  = "k3s-homelab",
          },
        ]
      }

      loki.source.file "host_logs" {
        targets    = local.file_match.host_logs.targets
        forward_to = [loki.write.loki.receiver]
      }

      // =========================================================================
      // Loki write endpoint
      // =========================================================================

      loki.write "loki" {
        endpoint {
          url = "${var.loki_url}"
        }
      }
    ALLOY
  }
}

# DaemonSet: Alloy runs on every node
resource "kubernetes_daemon_set_v1" "alloy" {
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
        service_account_name = kubernetes_service_account.alloy.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = local.app_name
          image = "grafana/alloy:${var.image_tag}"

          args = [
            "run",
            "/etc/alloy/config.alloy",
            "--storage.path=/var/lib/alloy/data",
            "--server.http.listen-addr=0.0.0.0:12345",
          ]

          port {
            name           = "http"
            container_port = 12345
            protocol       = "TCP"
          }

          # Inject node name for label construction
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          resources {
            requests = {
              memory = var.memory_request
              cpu    = var.cpu_request
            }
            limits = {
              memory = var.memory_limit
              cpu    = var.cpu_limit
            }
          }

          # Run as root to read /var/log/auth.log (requires adm group or root)
          security_context {
            run_as_user = 0
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/alloy"
            read_only  = true
          }

          volume_mount {
            name       = "pod-logs"
            mount_path = "/var/log/pods"
            read_only  = true
          }

          volume_mount {
            name       = "var-log"
            mount_path = "/var/log"
            read_only  = true
          }

          volume_mount {
            name       = "journal"
            mount_path = "/var/log/journal"
            read_only  = true
          }

          volume_mount {
            name       = "run-journal"
            mount_path = "/run/log/journal"
            read_only  = true
          }

          volume_mount {
            name       = "positions"
            mount_path = "/var/lib/alloy"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.alloy_config.metadata[0].name
          }
        }

        volume {
          name = "pod-logs"
          host_path {
            path = "/var/log/pods"
            type = "Directory"
          }
        }

        volume {
          name = "var-log"
          host_path {
            path = "/var/log"
            type = "Directory"
          }
        }

        volume {
          name = "journal"
          host_path {
            path = "/var/log/journal"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "run-journal"
          host_path {
            path = "/run/log/journal"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "positions"
          host_path {
            path = "/var/lib/alloy"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}

# Service: Alloy metrics endpoint
resource "kubernetes_service" "alloy" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "12345"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "http"
      port        = 12345
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
