locals {
  app_name = "hubble-ui"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "poc"
  }
}

# Ingress for Hubble UI - created in kube-system where the service lives
# TLS secret must exist in kube-system (copied from traefik namespace)
resource "kubernetes_ingress_v1" "hubble_ui" {
  metadata {
    name      = local.app_name
    namespace = "kube-system"
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = [var.hostname]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "hubble-ui"
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
