locals {
  app_name = "whoami"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "poc"
  }
}

resource "kubernetes_deployment" "whoami" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

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
        container {
          name  = local.app_name
          image = "traefik/whoami:${var.image_tag}"

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }

          env {
            name  = "TZ"
            value = "Europe/London"
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        # Allow scheduling on both amd64 and arm64 nodes
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64", "arm64"]
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whoami" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "whoami" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = ["whoami-k8s.brmartin.co.uk"]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = "whoami-k8s.brmartin.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.whoami.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# VPA for automatic resource recommendations
resource "kubectl_manifest" "whoami_vpa" {
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "${local.app_name}-vpa"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = local.app_name
      }
      updatePolicy = {
        updateMode = var.vpa_mode
      }
      resourcePolicy = {
        containerPolicies = [{
          containerName = local.app_name
          minAllowed = {
            cpu    = "5m"
            memory = "8Mi"
          }
          maxAllowed = {
            cpu    = "500m"
            memory = "256Mi"
          }
        }]
      }
    }
  })

  depends_on = [kubernetes_deployment.whoami]
}
