locals {
  app_name  = var.app_name
  namespace = var.namespace
  kubeconfig = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [
      {
        name = "in-cluster"
        cluster = {
          server                  = "https://kubernetes.default.svc"
          "certificate-authority" = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        }
      }
    ]
    users = [
      {
        name = "headlamp"
        user = {
          tokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        }
      }
    ]
    contexts = [
      {
        name = "service-account"
        context = {
          cluster = "in-cluster"
          user    = "headlamp"
        }
      }
    ]
    "current-context" = "service-account"
  })

  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "dashboard"
    "app.kubernetes.io/managed-by" = "terraform"
  }

  selector_labels = {
    "app.kubernetes.io/name"     = local.app_name
    "app.kubernetes.io/instance" = local.app_name
  }
}

# -----------------------------------------------------------------------------
# Kubeconfig
# Keep Headlamp's Kubernetes client on the pod service account so browser OIDC
# login only gates access to the UI and does not have to double as cluster auth.
# -----------------------------------------------------------------------------
resource "kubernetes_config_map" "headlamp_kubeconfig" {
  metadata {
    name      = "${local.app_name}-kubeconfig"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    config = local.kubeconfig
  }
}

# -----------------------------------------------------------------------------
# Deployment
# NOTE: OIDC client secret must be created manually before deploying:
#   kubectl create secret generic headlamp-oidc \
#     --namespace kube-system \
#     --from-literal=client-secret=<YOUR_KEYCLOAK_CLIENT_SECRET>
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "headlamp" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.selector_labels
    }

    template {
      metadata {
        labels = merge(local.labels, {
          version = var.image_tag
        })
      }

      spec {
        service_account_name = kubernetes_service_account.headlamp.metadata[0].name

        container {
          name  = "headlamp"
          image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

          args = [
            "-in-cluster",
            "-plugins-dir=/headlamp/plugins",
            "-kubeconfig=/home/headlamp/.config/Headlamp/kubeconfigs/config",
            "-skipped-kube-contexts=service-account",
            "-oidc-client-id=${var.oidc_client_id}",
            "-oidc-client-secret=$(OIDC_CLIENT_SECRET)",
            "-oidc-idp-issuer-url=${var.oidc_issuer_url}",
            "-oidc-scopes=${var.oidc_scopes}",
            "-oidc-validator-client-id=${var.oidc_client_id}",
            "-oidc-validator-idp-issuer-url=${var.oidc_issuer_url}",
            "-oidc-callback-url=https://${var.ingress_hostname}/oidc-callback",
            "-log-level=debug",
          ]

          env {
            name = "OIDC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-oidc"
                key  = "client-secret"
              }
            }
          }

          env {
            name  = "GODEBUG"
            value = "http2client=0"
          }

          port {
            container_port = 4466
            name           = "http"
            protocol       = "TCP"
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

          liveness_probe {
            http_get {
              path   = "/"
              port   = 4466
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            timeout_seconds       = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path   = "/"
              port   = 4466
              scheme = "HTTP"
            }
            initial_delay_seconds = 10
            timeout_seconds       = 10
            period_seconds        = 10
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 100
            run_as_group               = 101
            read_only_root_filesystem  = false
            allow_privilege_escalation = false

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "kubeconfig"
            mount_path = "/home/headlamp/.config/Headlamp/kubeconfigs/config"
            sub_path   = "config"
            read_only  = true
          }
        }

        node_selector = {
          "kubernetes.io/os" = "linux"
        }

        volume {
          name = "kubeconfig"
          config_map {
            name = kubernetes_config_map.headlamp_kubeconfig.metadata[0].name
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Service
# -----------------------------------------------------------------------------
resource "kubernetes_service" "headlamp" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"

    port {
      port        = 80
      target_port = "http"
      protocol    = "TCP"
      name        = "http"
    }

    selector = local.selector_labels
  }
}

# -----------------------------------------------------------------------------
# IngressRoute (Traefik)
# -----------------------------------------------------------------------------
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
        merge(
          {
            match = "Host(`${var.ingress_hostname}`)"
            kind  = "Rule"
            services = [
              {
                name = kubernetes_service.headlamp.metadata[0].name
                port = "http"
              }
            ]
          },
          length(var.traefik_middlewares) > 0 ? {
            middlewares = [
              for middleware in var.traefik_middlewares : {
                name      = middleware
                namespace = local.namespace
              }
            ]
          } : {}
        )
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  })
}
