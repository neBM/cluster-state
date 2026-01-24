locals {
  app_name = "jayne-martin-counselling"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "production"
  }
}

resource "kubernetes_deployment" "jayne_martin_counselling" {
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
          image = "registry.brmartin.co.uk/jayne-martin-counselling/website:${var.image_tag}"

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
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
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Registry credentials for GitLab container registry
        image_pull_secrets {
          name = "gitlab-registry"
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

resource "kubernetes_service" "jayne_martin_counselling" {
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

resource "kubernetes_ingress_v1" "jayne_martin_counselling" {
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
      hosts       = ["www.jaynemartincounselling.co.uk"]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = "www.jaynemartincounselling.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.jayne_martin_counselling.metadata[0].name
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
resource "kubectl_manifest" "jayne_martin_counselling_vpa" {
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
            memory = "16Mi"
          }
          maxAllowed = {
            cpu    = "200m"
            memory = "128Mi"
          }
        }]
      }
    }
  })

  depends_on = [kubernetes_deployment.jayne_martin_counselling]
}
