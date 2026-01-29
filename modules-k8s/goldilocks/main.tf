# Goldilocks - Automatic VPA recommendations for all workloads
#
# Goldilocks creates VPAs automatically for all Deployments/StatefulSets
# in namespaces labeled with: goldilocks.fairwinds.com/enabled=true
#
# VPAs are created in "Off" mode by default (recommend only, no auto-scaling)

locals {
  labels = {
    app        = "goldilocks"
    managed-by = "terraform"
  }
}

# =============================================================================
# Namespace label to enable Goldilocks
# =============================================================================

resource "kubernetes_labels" "enable_goldilocks" {
  for_each = toset(var.enabled_namespaces)

  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = each.value
  }
  labels = {
    "goldilocks.fairwinds.com/enabled"         = "true"
    "goldilocks.fairwinds.com/vpa-update-mode" = var.default_vpa_mode
  }
}

# =============================================================================
# ServiceAccount
# =============================================================================

resource "kubernetes_service_account" "goldilocks" {
  metadata {
    name      = "goldilocks"
    namespace = var.namespace
    labels    = local.labels
  }
}

# =============================================================================
# ClusterRole - needs to read deployments/statefulsets and manage VPAs
# =============================================================================

resource "kubernetes_cluster_role" "goldilocks" {
  metadata {
    name   = "goldilocks"
    labels = local.labels
  }

  # Read workloads
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  # Read batch resources
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  # Manage VPAs
  rule {
    api_groups = ["autoscaling.k8s.io"]
    resources  = ["verticalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Read namespaces (to check labels)
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  # Read pods (for metrics)
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "goldilocks" {
  metadata {
    name   = "goldilocks"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.goldilocks.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.goldilocks.metadata[0].name
    namespace = var.namespace
  }
}

# =============================================================================
# Goldilocks Controller Deployment
# =============================================================================

resource "kubernetes_deployment" "goldilocks_controller" {
  metadata {
    name      = "goldilocks-controller"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app       = "goldilocks"
        component = "controller"
      }
    }

    template {
      metadata {
        labels = {
          app        = "goldilocks"
          component  = "controller"
          managed-by = "terraform"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.goldilocks.metadata[0].name

        container {
          name  = "goldilocks"
          image = "${var.image}:${var.image_tag}"

          command = ["/goldilocks", "controller"]

          args = [
            "--on-by-default=false",
            "--exclude-namespaces=kube-system,kube-public,kube-node-lease",
            "-v=2"
          ]

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              # 1 full core - goldilocks reconciles 50+ VPAs in bursts
              # Tight limits cause throttling which extends burst duration
              # and keeps apiserver/etcd busy longer, causing RCU stalls
              cpu    = "1000m"
              memory = "128Mi"
            }
          }

          security_context {
            read_only_root_filesystem = true
            run_as_non_root           = true
            run_as_user               = 10324
          }
        }
      }
    }
  }
}

# =============================================================================
# Goldilocks Dashboard (optional, for viewing recommendations)
# =============================================================================

resource "kubernetes_deployment" "goldilocks_dashboard" {
  count = var.enable_dashboard ? 1 : 0

  metadata {
    name      = "goldilocks-dashboard"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app       = "goldilocks"
        component = "dashboard"
      }
    }

    template {
      metadata {
        labels = {
          app        = "goldilocks"
          component  = "dashboard"
          managed-by = "terraform"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.goldilocks.metadata[0].name

        container {
          name  = "goldilocks"
          image = "${var.image}:${var.image_tag}"

          command = ["/goldilocks", "dashboard", "--port=8080"]

          port {
            container_port = 8080
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          security_context {
            read_only_root_filesystem = true
            run_as_non_root           = true
            run_as_user               = 10324
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "goldilocks_dashboard" {
  count = var.enable_dashboard ? 1 : 0

  metadata {
    name      = "goldilocks-dashboard"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app       = "goldilocks"
      component = "dashboard"
    }

    port {
      port        = 8080
      target_port = 8080
      name        = "http"
    }
  }
}

# IngressRoute for dashboard
resource "kubectl_manifest" "goldilocks_ingressroute" {
  count = var.enable_dashboard && var.dashboard_host != "" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "goldilocks-dashboard"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.dashboard_host}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.goldilocks_dashboard[0].metadata[0].name
              port = 8080
            }
          ]
          middlewares = var.dashboard_middlewares
        }
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  })
}
