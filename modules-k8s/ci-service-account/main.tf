# CI Service Account for Terraform
# Provides limited RBAC permissions for GitLab CI pipelines

resource "kubernetes_service_account" "ci" {
  metadata {
    name      = var.service_account_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = var.service_account_name
      "app.kubernetes.io/component"  = "ci"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Long-lived token for the service account (K8s 1.24+)
resource "kubernetes_secret" "ci_token" {
  metadata {
    name      = "${var.service_account_name}-token"
    namespace = var.namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.ci.metadata[0].name
    }
    labels = {
      "app.kubernetes.io/name"       = var.service_account_name
      "app.kubernetes.io/component"  = "ci"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "kubernetes.io/service-account-token"
}

# ClusterRole with permissions needed for Terraform to manage K8s resources
resource "kubernetes_cluster_role" "ci" {
  metadata {
    name = var.service_account_name
    labels = {
      "app.kubernetes.io/name"       = var.service_account_name
      "app.kubernetes.io/component"  = "ci"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # Core API resources
  rule {
    api_groups = [""]
    resources = [
      "configmaps",
      "endpoints",
      "namespaces",
      "persistentvolumeclaims",
      "persistentvolumes",
      "pods",
      "secrets",
      "serviceaccounts",
      "services",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Apps API (Deployments, StatefulSets, DaemonSets, ReplicaSets)
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Batch API (Jobs, CronJobs)
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Networking (Ingress, NetworkPolicies)
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Storage
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # RBAC (for creating service accounts and roles within namespaces)
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # External Secrets Operator CRDs
  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets", "clustersecretstores", "secretstores"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Traefik CRDs (IngressRoutes, Middlewares, etc.)
  rule {
    api_groups = ["traefik.io", "traefik.containo.us"]
    resources  = ["ingressroutes", "ingressroutetcps", "ingressrouteudps", "middlewares", "middlewaretcps", "serverstransports", "tlsoptions", "tlsstores", "traefikservices"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # VPA (Vertical Pod Autoscaler)
  rule {
    api_groups = ["autoscaling.k8s.io"]
    resources  = ["verticalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Cilium Network Policies
  rule {
    api_groups = ["cilium.io"]
    resources  = ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Policy API (PodDisruptionBudgets)
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Autoscaling (HPA)
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

# Bind the ClusterRole to the ServiceAccount
resource "kubernetes_cluster_role_binding" "ci" {
  metadata {
    name = var.service_account_name
    labels = {
      "app.kubernetes.io/name"       = var.service_account_name
      "app.kubernetes.io/component"  = "ci"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.ci.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ci.metadata[0].name
    namespace = var.namespace
  }
}
