locals {
  app_name = "nfs-subdir-external-provisioner"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
}

# ServiceAccount for the provisioner
resource "kubernetes_service_account" "provisioner" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }
}

# ClusterRole with permissions to manage PV/PVC
resource "kubernetes_cluster_role" "provisioner" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  # Core resources for provisioning
  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "update"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }

  # Events for status reporting
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "update", "patch"]
  }

  # Endpoints for leader election (if running multiple replicas)
  rule {
    api_groups = [""]
    resources  = ["endpoints"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  # Nodes to get node info
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

# ClusterRoleBinding to link ServiceAccount to ClusterRole
resource "kubernetes_cluster_role_binding" "provisioner" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.provisioner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.provisioner.metadata[0].name
    namespace = var.namespace
  }
}

# Deployment for the NFS provisioner
resource "kubernetes_deployment" "provisioner" {
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
      match_labels = {
        app = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name = kubernetes_service_account.provisioner.metadata[0].name

        container {
          name  = "nfs-provisioner"
          image = var.provisioner_image

          env {
            name  = "PROVISIONER_NAME"
            value = "nfs.io/nfs-subdir-external-provisioner"
          }

          env {
            name  = "NFS_SERVER"
            value = var.nfs_server
          }

          env {
            name  = "NFS_PATH"
            value = var.nfs_path
          }

          volume_mount {
            name       = "nfs-root"
            mount_path = "/persistentvolumes"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "nfs-root"
          nfs {
            server = var.nfs_server
            path   = var.nfs_path
          }
        }

        # Run on any node - NFS is available on all nodes via localhost
      }
    }
  }

  depends_on = [kubernetes_cluster_role_binding.provisioner]
}
