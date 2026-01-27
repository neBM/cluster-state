resource "kubernetes_service_account" "meshery" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "meshery" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  # Meshery needs broad permissions for service mesh management
  rule {
    api_groups = [""]
    resources = [
      "nodes",
      "namespaces",
      "pods",
      "services",
      "configmaps",
      "endpoints",
      "persistentvolumeclaims",
      "secrets",
      "serviceaccounts",
      "services/proxy",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources = [
      "deployments",
      "daemonsets",
      "replicasets",
      "statefulsets",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources = [
      "jobs",
      "cronjobs",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # RBAC permissions
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources = [
      "clusterroles",
      "clusterrolebindings",
      "roles",
      "rolebindings",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Networking permissions
  rule {
    api_groups = ["networking.k8s.io"]
    resources = [
      "networkpolicies",
      "ingresses",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # CRD permissions
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources = [
      "customresourcedefinitions",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Cilium specific permissions
  rule {
    api_groups = ["cilium.io"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Metrics permissions
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list"]
  }

  # Admission registration
  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources = [
      "mutatingwebhookconfigurations",
      "validatingwebhookconfigurations",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "meshery" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.meshery.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.meshery.metadata[0].name
    namespace = local.namespace
  }
}