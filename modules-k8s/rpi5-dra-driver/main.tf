locals {
  name   = "rpi5-dra-driver"
  labels = { app = local.name, "managed-by" = "terraform" }
}

resource "kubernetes_service_account" "driver" {
  metadata {
    name      = local.name
    namespace = "kube-system"
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "driver" {
  metadata {
    name   = local.name
    labels = local.labels
  }
  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["resourceslices"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["resourceclaims"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "driver" {
  metadata {
    name   = local.name
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.driver.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.driver.metadata[0].name
    namespace = "kube-system"
  }
}

resource "kubernetes_daemon_set_v1" "driver" {
  metadata {
    name      = local.name
    namespace = "kube-system"
    labels    = local.labels
  }

  spec {
    selector { match_labels = local.labels }

    template {
      metadata { labels = local.labels }

      spec {
        service_account_name = kubernetes_service_account.driver.metadata[0].name
        priority_class_name  = "system-node-critical"

        container {
          name              = "driver"
          image             = var.image
          image_pull_policy = "Always"

          env {
            name = "NODE_NAME"
            value_from {
              field_ref { field_path = "spec.nodeName" }
            }
          }

          security_context { privileged = true }

          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }
          volume_mount {
            name       = "kubelet-plugins"
            mount_path = "/var/lib/kubelet/plugins"
          }
          volume_mount {
            name       = "kubelet-registry"
            mount_path = "/var/lib/kubelet/plugins_registry"
          }
          volume_mount {
            name       = "cdi"
            mount_path = "/var/run/cdi"
          }
        }

        volume {
          name = "dev"
          host_path { path = "/dev" }
        }
        volume {
          name = "kubelet-plugins"
          host_path { path = "/var/lib/kubelet/plugins" }
        }
        volume {
          name = "kubelet-registry"
          host_path { path = "/var/lib/kubelet/plugins_registry" }
        }
        volume {
          name = "cdi"
          host_path {
            path = "/var/run/cdi"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}
