# Elastic Agent DaemonSet for Kubernetes log collection
# Based on Kibana Fleet-generated manifest with K3s fixes

resource "kubernetes_namespace" "elastic_system" {
  metadata {
    name = var.namespace
  }
}

# ServiceAccount
resource "kubernetes_service_account" "elastic_agent" {
  metadata {
    name      = "elastic-agent"
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "elastic-agent"
    }
  }
}

# ClusterRole with permissions for K8s metrics, logs, and cloudbeat
resource "kubernetes_cluster_role" "elastic_agent" {
  metadata {
    name = "elastic-agent"
    labels = {
      "app.kubernetes.io/name" = "elastic-agent"
    }
  }

  rule {
    api_groups = [""]
    resources = [
      "nodes",
      "namespaces",
      "events",
      "pods",
      "services",
      "configmaps",
      "serviceaccounts",
      "persistentvolumes",
      "persistentvolumeclaims",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources = [
      "statefulsets",
      "deployments",
      "replicasets",
      "daemonsets",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes/stats"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  # Needed for apiserver metrics
  rule {
    non_resource_urls = ["/metrics"]
    verbs             = ["get"]
  }

  # Needed for cloudbeat
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources = [
      "clusterrolebindings",
      "clusterroles",
      "rolebindings",
      "roles",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["policy"]
    resources  = ["podsecuritypolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

# ClusterRoleBinding
resource "kubernetes_cluster_role_binding" "elastic_agent" {
  metadata {
    name = "elastic-agent"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.elastic_agent.metadata[0].name
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.elastic_agent.metadata[0].name
  }
}

# Role for leader election (leases)
resource "kubernetes_role" "elastic_agent" {
  metadata {
    name      = "elastic-agent"
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "elastic-agent"
    }
  }

  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "create", "update"]
  }
}

# RoleBinding for leader election
resource "kubernetes_role_binding" "elastic_agent" {
  metadata {
    name      = "elastic-agent"
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.elastic_agent.metadata[0].name
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.elastic_agent.metadata[0].name
  }
}

# Role for kubeadm-config access (kube-system namespace)
resource "kubernetes_role" "elastic_agent_kubeadm_config" {
  metadata {
    name      = "elastic-agent-kubeadm-config"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "elastic-agent"
    }
  }

  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["kubeadm-config"]
    verbs          = ["get"]
  }
}

# RoleBinding for kubeadm-config
resource "kubernetes_role_binding" "elastic_agent_kubeadm_config" {
  metadata {
    name      = "elastic-agent-kubeadm-config"
    namespace = "kube-system"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.elastic_agent.metadata[0].name
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.elastic_agent_kubeadm_config.metadata[0].name
  }
}

# DaemonSet
resource "kubernetes_daemon_set_v1" "elastic_agent" {
  metadata {
    name      = "elastic-agent"
    namespace = kubernetes_namespace.elastic_system.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "elastic-agent"
    }
  }

  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "elastic-agent"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "elastic-agent"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.elastic_agent.metadata[0].name
        host_network         = true
        dns_policy           = "ClusterFirstWithHostNet"

        # Run on control-plane nodes too
        toleration {
          key    = "node-role.kubernetes.io/control-plane"
          effect = "NoSchedule"
        }

        toleration {
          key    = "node-role.kubernetes.io/master"
          effect = "NoSchedule"
        }

        container {
          name  = "elastic-agent"
          image = "${var.elastic_agent_image}:${var.elastic_agent_tag}"

          env {
            name  = "FLEET_ENROLL"
            value = "1"
          }

          env {
            name  = "FLEET_INSECURE"
            value = var.fleet_insecure ? "true" : "false"
          }

          env {
            name  = "FLEET_URL"
            value = var.fleet_url
          }

          env {
            name = "FLEET_ENROLLMENT_TOKEN"
            value_from {
              secret_key_ref {
                name = var.enrollment_token_secret_name
                key  = var.enrollment_token_secret_key
              }
            }
          }

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          # Disable netinfo to avoid host.ip and host.mac fields
          env {
            name  = "ELASTIC_NETINFO"
            value = "false"
          }

          security_context {
            run_as_user = 0
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              memory = var.memory_limit
            }
          }

          # Volume mounts for log collection and metrics
          volume_mount {
            name       = "proc"
            mount_path = "/hostfs/proc"
            read_only  = true
          }

          volume_mount {
            name       = "cgroup"
            mount_path = "/hostfs/sys/fs/cgroup"
            read_only  = true
          }

          volume_mount {
            name       = "varlibdockercontainers"
            mount_path = "/var/lib/docker/containers"
            read_only  = true
          }

          # K3s containerd path
          volume_mount {
            name       = "varlibrancher"
            mount_path = "/var/lib/rancher"
            read_only  = true
          }

          volume_mount {
            name       = "varlog"
            mount_path = "/var/log"
            read_only  = true
          }

          volume_mount {
            name       = "etc-full"
            mount_path = "/hostfs/etc"
            read_only  = true
          }

          volume_mount {
            name       = "var-lib"
            mount_path = "/hostfs/var/lib"
            read_only  = true
          }

          volume_mount {
            name       = "etc-mid"
            mount_path = "/etc/machine-id"
            read_only  = true
          }

          volume_mount {
            name       = "sys-kernel-debug"
            mount_path = "/sys/kernel/debug"
          }

          volume_mount {
            name       = "elastic-agent-state"
            mount_path = "/usr/share/elastic-agent/state"
          }
        }

        volume {
          name = "proc"
          host_path {
            path = "/proc"
          }
        }

        volume {
          name = "cgroup"
          host_path {
            path = "/sys/fs/cgroup"
          }
        }

        volume {
          name = "varlibdockercontainers"
          host_path {
            path = "/var/lib/docker/containers"
          }
        }

        # K3s containerd logs
        volume {
          name = "varlibrancher"
          host_path {
            path = "/var/lib/rancher"
          }
        }

        volume {
          name = "varlog"
          host_path {
            path = "/var/log"
          }
        }

        volume {
          name = "etc-full"
          host_path {
            path = "/etc"
          }
        }

        volume {
          name = "var-lib"
          host_path {
            path = "/var/lib"
          }
        }

        volume {
          name = "etc-mid"
          host_path {
            path = "/etc/machine-id"
            type = "File"
          }
        }

        volume {
          name = "sys-kernel-debug"
          host_path {
            path = "/sys/kernel/debug"
          }
        }

        # Persist agent state across restarts
        volume {
          name = "elastic-agent-state"
          host_path {
            path = "/var/lib/elastic-agent-managed/${var.namespace}/state"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}
