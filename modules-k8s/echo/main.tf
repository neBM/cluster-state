locals {
  app_name = "echo"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "poc"
  }
}

resource "kubernetes_deployment" "echo" {
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
          image = "ealen/echo-server:${var.image_tag}"

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
            name  = "PORT"
            value = "80"
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/"
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

resource "kubernetes_service" "echo" {
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

# CiliumNetworkPolicy to restrict access (replaces Consul intentions)
resource "kubectl_manifest" "network_policy" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "allow-to-${local.app_name}"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          app = local.app_name
        }
      }
      ingress = [
        {
          fromEndpoints = [
            for source in var.allowed_sources : {
              matchLabels = {
                app = source
              }
            }
          ]
          toPorts = [{
            ports = [{
              port     = "80"
              protocol = "TCP"
            }]
          }]
        }
      ]
    }
  })

  depends_on = [kubernetes_deployment.echo]
}
