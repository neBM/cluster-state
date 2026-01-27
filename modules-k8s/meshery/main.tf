locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "service-mesh-management"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# Meshery Deployment
resource "kubernetes_deployment" "meshery" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = local.app_name
        "app.kubernetes.io/instance" = local.app_name
      }
    }

    template {
      metadata {
        labels = merge(local.labels, {
          "app.kubernetes.io/version" = var.image_tag
        })
      }

      spec {
        service_account_name = kubernetes_service_account.meshery.metadata[0].name

        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        container {
          name  = local.app_name
          image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          env {
            name  = "PROVIDER_BASE_URLS"
            value = ""
          }

          env {
            name  = "PROVIDER"
            value = "None"
          }

          env {
            name  = "ADAPTER_URLS"
            value = "localhost:10000"
          }

          # Enable Cilium adapter
          env {
            name  = "MESHERY_ADAPTER_CILIUM_ENABLED"
            value = "true"
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          startup_probe {
            http_get {
              path = "/api/system/ping"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30
          }

          liveness_probe {
            http_get {
              path = "/api/system/ping"
              port = "http"
            }
            initial_delay_seconds = 0
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/api/system/ping"
              port = "http"
            }
            initial_delay_seconds = 0
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }
      }
    }
  }
}

# Meshery Service
resource "kubernetes_service" "meshery" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "http"
      port        = 9081
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# Meshery IngressRoute
resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = local.app_name
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.ingress_hostname}`)"
          kind  = "Rule"
          middlewares = var.traefik_middlewares != [] ? [
            for middleware in var.traefik_middlewares : {
              name      = middleware
              namespace = local.namespace
            }
          ] : null
          services = [
            {
              name = kubernetes_service.meshery.metadata[0].name
              port = "http"
            }
          ]
        }
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  })
}