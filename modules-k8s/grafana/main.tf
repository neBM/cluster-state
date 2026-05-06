locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "monitoring"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# ConfigMap for Prometheus datasource provisioning
resource "kubernetes_config_map_v1" "datasources" {
  metadata {
    name      = "${local.app_name}-datasources"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "prometheus.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Prometheus"
          type      = "prometheus"
          uid       = "prometheus"
          access    = "proxy"
          url       = var.prometheus_url
          isDefault = true
          editable  = false
        }
      ]
    })

    "loki.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          access    = "proxy"
          url       = var.loki_url
          isDefault = false
          editable  = true
          version   = 1
          jsonData = {
            maxLines = 1000
            timeout  = 60
          }
        }
      ]
    })
  }
}

# Alert rules are managed through Grafana's alerting API via Terraform.
# Keep only contact points and notification policy file-provisioned here.
resource "kubernetes_config_map_v1" "alerting" {
  metadata {
    name      = "${local.app_name}-alerting"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    # Contact point: email via SMTP relay.
    # The recipient address is injected from the GF_ALERT_EMAIL_TO env var
    # (sourced from the grafana-smtp K8s secret) so it is never committed to git.
    "contactpoints.yaml" = yamlencode({
      apiVersion = 1
      contactPoints = [
        {
          orgId = 1
          name  = "email"
          receivers = [
            {
              uid  = "email-alerts"
              type = "email"
              settings = {
                addresses = "$${GF_ALERT_EMAIL_TO}"
              }
            }
          ]
        }
      ]
    })

    # Default notification policy: route all alerts to the email contact point.
    "policies.yaml" = yamlencode({
      apiVersion = 1
      policies = [
        {
          orgId    = 1
          receiver = "email"
        }
      ]
    })
  }
}

# PVC for Grafana data
resource "kubernetes_persistent_volume_claim_v1" "grafana_data" {
  metadata {
    name      = "${local.app_name}-data"
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "volume-name" = "${local.app_name}_data"
    }
  }

  spec {
    storage_class_name = var.storage_class
    access_modes       = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# Grafana Deployment with OAuth
resource "kubernetes_deployment_v1" "grafana" {
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
        annotations = {
          "checksum/datasources" = sha256(jsonencode(kubernetes_config_map_v1.datasources.data))
          "checksum/alerting"    = sha256(jsonencode(kubernetes_config_map_v1.alerting.data))
        }
        labels = merge(local.labels, {
          "app.kubernetes.io/version" = var.image_tag
        })
      }

      spec {
        container {
          name  = local.app_name
          image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }

          # OAuth configuration
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ENABLED"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_NAME"
            value = "Keycloak"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
            value = var.keycloak_client_id
          }
          env {
            name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "OAUTH_CLIENT_SECRET"
              }
            }
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_SCOPES"
            value = "openid email profile"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_NAME"
            value = "email"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH"
            value = "email"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_AUTH_URL"
            value = "${var.keycloak_url}/realms/${var.keycloak_realm}/protocol/openid-connect/auth"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_TOKEN_URL"
            value = "${var.keycloak_url}/realms/${var.keycloak_realm}/protocol/openid-connect/token"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_API_URL"
            value = "${var.keycloak_url}/realms/${var.keycloak_realm}/protocol/openid-connect/userinfo"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE"
            value = "false"
          }

          # Server configuration
          env {
            name  = "GF_SERVER_ROOT_URL"
            value = "https://${var.ingress_hostname}"
          }

          # Admin password
          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "GF_SECURITY_ADMIN_PASSWORD"
              }
            }
          }

          # SMTP / email alerting
          env {
            name  = "GF_SMTP_ENABLED"
            value = "true"
          }
          env {
            name  = "GF_SMTP_HOST"
            value = "mail.brmartin.co.uk:587"
          }
          env {
            name  = "GF_SMTP_FROM_ADDRESS"
            value = "services@brmartin.co.uk"
          }
          env {
            name  = "GF_SMTP_FROM_NAME"
            value = "Grafana"
          }
          env {
            name  = "GF_SMTP_STARTTLS_POLICY"
            value = "MandatoryStartTLS"
          }
          env {
            name = "GF_SMTP_USER"
            value_from {
              secret_key_ref {
                name = "grafana-smtp"
                key  = "GF_SMTP_USER"
              }
            }
          }
          env {
            name = "GF_SMTP_PASSWORD"
            value_from {
              secret_key_ref {
                name = "grafana-smtp"
                key  = "GF_SMTP_PASSWORD"
              }
            }
          }
          env {
            name = "GF_ALERT_EMAIL_TO"
            value_from {
              secret_key_ref {
                name = "grafana-smtp"
                key  = "GF_ALERT_EMAIL_TO"
              }
            }
          }

          # Database path
          env {
            name  = "GF_PATHS_DATA"
            value = "/var/lib/grafana"
          }
          env {
            name  = "GF_PATHS_LOGS"
            value = "/var/log/grafana"
          }
          env {
            name  = "GF_PATHS_PLUGINS"
            value = "/var/lib/grafana/plugins"
          }
          env {
            name  = "GF_PATHS_PROVISIONING"
            value = "/etc/grafana/provisioning"
          }
          env {
            name  = "GF_PLUGINS_PREINSTALL_DISABLED"
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

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/grafana"
          }

          volume_mount {
            name       = "datasources"
            mount_path = "/etc/grafana/provisioning/datasources/prometheus.yaml"
            sub_path   = "prometheus.yaml"
            read_only  = true
          }

          volume_mount {
            name       = "datasources"
            mount_path = "/etc/grafana/provisioning/datasources/loki.yaml"
            sub_path   = "loki.yaml"
            read_only  = true
          }

          volume_mount {
            name       = "alerting"
            mount_path = "/etc/grafana/provisioning/alerting/contactpoints.yaml"
            sub_path   = "contactpoints.yaml"
            read_only  = true
          }

          volume_mount {
            name       = "alerting"
            mount_path = "/etc/grafana/provisioning/alerting/policies.yaml"
            sub_path   = "policies.yaml"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.grafana_data.metadata[0].name
          }
        }

        volume {
          name = "datasources"
          config_map {
            name = kubernetes_config_map_v1.datasources.metadata[0].name
          }
        }

        volume {
          name = "alerting"
          config_map {
            name = kubernetes_config_map_v1.alerting.metadata[0].name
          }
        }
      }
    }
  }
}

# Grafana Service
resource "kubernetes_service_v1" "grafana" {
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
      port        = 3000
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# Grafana IngressRoute
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
              name = kubernetes_service_v1.grafana.metadata[0].name
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
