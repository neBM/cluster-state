# lldap - Lightweight LDAP identity store
#
# PostgreSQL-backed LDAP server providing authentication for the mail stack.
# Keycloak federates from lldap in READ_ONLY mode.
# Admin UI is exposed via Traefik IngressRoute and protected by Keycloak OIDC (configured separately).

locals {
  app_name = "lldap"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

# =============================================================================
# ConfigMap (T009)
# =============================================================================

resource "kubernetes_config_map" "lldap_config" {
  metadata {
    name      = "lldap-config"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "lldap_config.toml" = <<-TOML
      ## lldap configuration
      ## Database URL is provided via LLDAP_DATABASE_URL env var.
      ## JWT secret and key seed are provided via LLDAP_JWT_SECRET / LLDAP_KEY_SEED env vars.

      [ldap]
      ldap_port = 3890
      base_dn = "${var.ldap_base_dn}"

      [http]
      http_port = 17170
      http_url = "https://${var.hostname}/"

      [verbose]
      verbose = false
    TOML
  }
}

# =============================================================================
# Deployment (T009)
# =============================================================================

resource "kubernetes_deployment" "lldap" {
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
          name = local.app_name
          # renovate: datasource=docker depName=lldap/lldap
          image = "lldap/lldap:${var.image_tag}"

          port {
            name           = "ldap"
            container_port = 3890
            protocol       = "TCP"
          }

          port {
            name           = "http"
            container_port = 17170
            protocol       = "TCP"
          }

          # NOTE: We do NOT mount the ConfigMap into /data/ — the lldap entrypoint
          # tries to chown /data which fails on a ConfigMap-backed read-only file.
          # Instead, base_dn and other settings are passed via LLDAP_ env vars below,
          # which lldap reads as overrides at startup (takes precedence over config file).

          env {
            name = "LLDAP_JWT_SECRET"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.lldap_secrets.metadata[0].name
                key  = "LLDAP_JWT_SECRET"
              }
            }
          }

          env {
            name = "LLDAP_KEY_SEED"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.lldap_secrets.metadata[0].name
                key  = "LLDAP_KEY_SEED"
              }
            }
          }

          env {
            name = "LLDAP_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.lldap_db.metadata[0].name
                key  = "LLDAP_DATABASE_URL"
              }
            }
          }

          env {
            name = "LLDAP_LDAP_USER_PASS"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.lldap_admin.metadata[0].name
                key  = "LLDAP_LDAP_USER_PASS"
              }
            }
          }

          # Base DN and HTTP URL — passed as env vars so lldap uses them instead
          # of the default config (which defaults to dc=example,dc=com)
          env {
            name  = "LLDAP_LDAP_BASE_DN"
            value = var.ldap_base_dn
          }

          env {
            name  = "LLDAP_HTTP_URL"
            value = "https://${var.hostname}/"
          }



          liveness_probe {
            http_get {
              path = "/health"
              port = 17170
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 17170
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "512Mi"
            }
          }
        }

        # No volumes needed — lldap config is provided entirely via LLDAP_ env vars
      }
    }
  }
}

# =============================================================================
# Service (T009)
# =============================================================================

resource "kubernetes_service" "lldap" {
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
      name        = "ldap"
      port        = 3890
      target_port = 3890
      protocol    = "TCP"
    }

    port {
      name        = "http"
      port        = 17170
      target_port = 17170
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Ingress (T009)
# =============================================================================

resource "kubernetes_ingress_v1" "lldap" {
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
              name = kubernetes_service.lldap.metadata[0].name
              port {
                number = 17170
              }
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Network Policy (T011)
# =============================================================================

# CiliumNetworkPolicy: restrict access to lldap to only authorised consumers.
# Port 3890 (LDAP): postfix, dovecot, sogo (mail stack) + keycloak (federation)
# Port 17170 (HTTP admin UI): Traefik only (pod label: app.kubernetes.io/name=traefik)
# All other ingress is denied by default.
resource "kubernetes_manifest" "lldap_network_policy" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "lldap"
      namespace = var.namespace
    }
    spec = {
      endpointSelector = {
        matchLabels = {
          app = "lldap"
        }
      }
      ingress = [
        # LDAP (3890): mail components and keycloak
        {
          fromEndpoints = [
            { matchLabels = { app = "postfix" } },
            { matchLabels = { app = "dovecot" } },
            { matchLabels = { app = "sogo" } },
            { matchLabels = { app = "keycloak" } },
          ]
          toPorts = [
            {
              ports = [
                { port = "3890", protocol = "TCP" }
              ]
            }
          ]
        },
        # HTTP admin UI (17170): Traefik ingress controller only (in traefik namespace)
        {
          fromEndpoints = [
            {
              matchLabels = {
                "app.kubernetes.io/name"          = "traefik"
                "k8s:io.kubernetes.pod.namespace" = "traefik"
              }
            },
          ]
          toPorts = [
            {
              ports = [
                { port = "17170", protocol = "TCP" }
              ]
            }
          ]
        },
      ]
    }
  }
}
