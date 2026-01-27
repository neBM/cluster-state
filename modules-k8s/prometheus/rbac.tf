resource "kubernetes_service_account" "prometheus" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "prometheus" {
  metadata {
    name   = "${local.app_name}-server"
    labels = local.labels
  }

  # API groups: "" (core), apps, batch
  rule {
    api_groups = [""]
    resources = [
      "nodes",
      "nodes/metrics",
      "nodes/proxy",
      "services",
      "endpoints",
      "pods",
      "ingresses"
    ]
    verbs = ["get", "list", "watch"]
  }

  # For service discovery of pods/services
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get"]
  }

  # For monitoring deployments, daemonsets, etc
  rule {
    api_groups = ["apps"]
    resources = [
      "deployments",
      "daemonsets",
      "replicasets",
      "statefulsets"
    ]
    verbs = ["get", "list", "watch"]
  }

  # For monitoring jobs and cronjobs
  rule {
    api_groups = ["batch"]
    resources = [
      "jobs",
      "cronjobs"
    ]
    verbs = ["get", "list", "watch"]
  }

  # For ingress discovery
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }

  # For /metrics endpoint access on nodes
  rule {
    non_resource_urls = ["/metrics", "/metrics/cadvisor"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "prometheus" {
  metadata {
    name   = "${local.app_name}-server"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.prometheus.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.prometheus.metadata[0].name
    namespace = local.namespace
  }
}