resource "kubernetes_service_account" "kube_state_metrics" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "kube_state_metrics" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  # Read access to most Kubernetes objects for metrics collection
  rule {
    api_groups = [""]
    resources = [
      "configmaps",
      "secrets",
      "nodes",
      "pods",
      "services",
      "serviceaccounts",
      "resourcequotas",
      "replicationcontrollers",
      "limitranges",
      "persistentvolumeclaims",
      "persistentvolumes",
      "namespaces",
      "endpoints",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources = [
      "statefulsets",
      "daemonsets",
      "deployments",
      "replicasets",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources = [
      "cronjobs",
      "jobs",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources = [
      "horizontalpodautoscalers",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["authentication.k8s.io"]
    resources = [
      "tokenreviews",
    ]
    verbs = ["create"]
  }

  rule {
    api_groups = ["authorization.k8s.io"]
    resources = [
      "subjectaccessreviews",
    ]
    verbs = ["create"]
  }

  rule {
    api_groups = ["policy"]
    resources = [
      "poddisruptionbudgets",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["certificates.k8s.io"]
    resources = [
      "certificatesigningrequests",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources = [
      "endpointslices",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources = [
      "storageclasses",
      "volumeattachments",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources = [
      "mutatingwebhookconfigurations",
      "validatingwebhookconfigurations",
    ]
    verbs = ["list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources = [
      "networkpolicies",
      "ingressclasses",
      "ingresses",
    ]
    verbs = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "kube_state_metrics" {
  metadata {
    name   = local.app_name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.kube_state_metrics.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.kube_state_metrics.metadata[0].name
    namespace = local.namespace
  }
}