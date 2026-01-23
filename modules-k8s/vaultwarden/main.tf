locals {
  app_name = "vaultwarden"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

# ExternalSecret to pull credentials from Vault
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.app_name}-secrets"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "${local.app_name}-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "DATABASE_URL"
          remoteRef = {
            key      = "nomad/data/default/vaultwarden"
            property = "DATABASE_URL"
          }
        },
        {
          secretKey = "SMTP_PASSWORD"
          remoteRef = {
            key      = "nomad/data/default/vaultwarden"
            property = "SMTP_PASSWORD"
          }
        },
        {
          secretKey = "ADMIN_TOKEN"
          remoteRef = {
            key      = "nomad/data/default/vaultwarden"
            property = "ADMIN_TOKEN"
          }
        }
      ]
    }
  })
}

resource "kubernetes_deployment" "vaultwarden" {
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
          name  = "vaultwarden"
          image = "vaultwarden/server:${var.image_tag}"

          port {
            container_port = 80
            name           = "http"
          }

          env {
            name  = "DOMAIN"
            value = "https://${var.hostname}"
          }

          env {
            name  = "SIGNUPS_ALLOWED"
            value = "false"
          }

          env {
            name  = "SMTP_HOST"
            value = "mail.brmartin.co.uk"
          }

          env {
            name  = "SMTP_FROM"
            value = "services@brmartin.co.uk"
          }

          env {
            name  = "SMTP_PORT"
            value = "587"
          }

          env {
            name  = "SMTP_SECURITY"
            value = "starttls"
          }

          env {
            name  = "SMTP_USERNAME"
            value = "ben@brmartin.co.uk"
          }

          env {
            name  = "ROCKET_PORT"
            value = "80"
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "DATABASE_URL"
              }
            }
          }

          env {
            name = "SMTP_PASSWORD"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "SMTP_PASSWORD"
              }
            }
          }

          env {
            name = "ADMIN_TOKEN"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "ADMIN_TOKEN"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/alive"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/alive"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "data"
          host_path {
            path = "/storage/v/glusterfs_vaultwarden_data"
            type = "Directory"
          }
        }

        # Multi-arch support
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

  depends_on = [kubectl_manifest.external_secret]
}

resource "kubernetes_service" "vaultwarden" {
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

resource "kubernetes_ingress_v1" "vaultwarden" {
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
              name = kubernetes_service.vaultwarden.metadata[0].name
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
