locals {
  app_name = "keycloak"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

# Deployment for Keycloak
resource "kubernetes_deployment" "keycloak" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate" # Avoid multiple instances during update
    }

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
          image = "quay.io/keycloak/keycloak:${var.image_tag}"

          args = ["start"]

          port {
            container_port = 8080
            name           = "http"
          }

          port {
            container_port = 9000
            name           = "management"
          }

          # Database configuration
          env {
            name  = "KC_DB"
            value = "postgres"
          }

          env {
            name  = "KC_DB_USERNAME"
            value = var.db_username
          }

          env {
            name  = "KC_DB_URL_HOST"
            value = var.db_host
          }

          env {
            name  = "KC_DB_URL_PORT"
            value = var.db_port
          }

          env {
            name  = "KC_DB_URL_DATABASE"
            value = var.db_name
          }

          env {
            name  = "KC_DB_URL_PROPERTIES"
            value = "?sslmode=disable"
          }

          # DB password from secret
          env {
            name = "KC_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "KC_DB_PASSWORD"
              }
            }
          }

          # HTTP/Proxy configuration
          env {
            name  = "KC_HTTP_ENABLED"
            value = "true"
          }

          env {
            name  = "KC_PROXY_HEADERS"
            value = "xforwarded"
          }

          env {
            name  = "KC_HTTP_HOST"
            value = "0.0.0.0" # Listen on all interfaces in K8s
          }

          env {
            name  = "KC_HOSTNAME"
            value = var.hostname
          }

          # Health endpoints
          env {
            name  = "KC_HEALTH_ENABLED"
            value = "true"
          }

          # Metrics endpoint (on management port 9000)
          env {
            name  = "KC_METRICS_ENABLED"
            value = "true"
          }

          # Java heap settings
          env {
            name  = "JAVA_OPTS_KC_HEAP"
            value = "-Xms200m -Xmx512m"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "768Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health/live"
              port = 9000 # Management port
            }
            initial_delay_seconds = 120 # Keycloak takes ~2 mins to start on ARM
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 9000 # Management port
            }
            initial_delay_seconds = 120
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

resource "kubernetes_service" "keycloak" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9000"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
      name        = "http"
    }

    port {
      port        = 9000
      target_port = 9000
      protocol    = "TCP"
      name        = "management"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "keycloak" {
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
              name = kubernetes_service.keycloak.metadata[0].name
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
