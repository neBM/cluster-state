resource "kubernetes_service_account" "headlamp" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }
}

# Bind to the built-in cluster-admin ClusterRole
# Headlamp needs broad access to display and manage all cluster resources
resource "kubernetes_cluster_role_binding" "headlamp" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.headlamp.metadata[0].name
    namespace = local.namespace
  }
}
