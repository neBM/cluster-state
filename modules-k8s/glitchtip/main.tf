locals {
  app_name = "glitchtip"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }

  common_env = [
    {
      name  = "GLITCHTIP_DOMAIN"
      value = "https://${var.hostname}"
    },
    {
      name  = "ALLOWED_HOSTS"
      value = var.hostname
    },
    {
      name  = "CSRF_TRUSTED_ORIGINS"
      value = "https://${var.hostname}"
    },
    {
      name  = "GLITCHTIP_EMBED_WORKER"
      value = "true"
    },
    {
      name  = "SKIP_INIT"
      value = "true"
    },
    {
      name  = "VALKEY_URL"
      value = "redis://valkey.default.svc.cluster.local:6379/0"
    },
    {
      name  = "ENABLE_USER_REGISTRATION"
      value = "false"
    },
    {
      name  = "ENABLE_SOCIAL_APPS_USER_REGISTRATION"
      value = "true"
    },
    {
      name  = "LOG_LEVEL"
      value = "INFO"
    },
  ]

  oidc_server_url = "https://sso.brmartin.co.uk/realms/prod/.well-known/openid-configuration"
}

resource "kubernetes_persistent_volume_claim_v1" "uploads" {
  metadata {
    name      = "${local.app_name}-uploads"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_service_v1" "glitchtip" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      name        = "http"
      port        = 80
      target_port = 8000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "glitchtip" {
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
              name = kubernetes_service_v1.glitchtip.metadata[0].name
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

resource "kubernetes_deployment_v1" "glitchtip" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        security_context {
          fs_group               = 5000
          fs_group_change_policy = "OnRootMismatch"
        }

        init_container {
          name  = "bootstrap"
          image = "glitchtip/glitchtip:${var.image_tag}"

          command = ["/bin/sh", "-ec"]
          args = [<<-EOF
            set -eu

            until python manage.py migrate --noinput; do
              echo "Waiting for PostgreSQL..."
              sleep 5
            done

            python manage.py shell <<'PY'
            import os
            from django.contrib.auth import get_user_model
            from django.contrib.sites.models import Site
            from allauth.socialaccount.models import SocialApp

            username = os.environ["DJANGO_SUPERUSER_USERNAME"]
            email = os.environ["DJANGO_SUPERUSER_EMAIL"]
            password = os.environ["DJANGO_SUPERUSER_PASSWORD"]
            site_domain = os.environ["GLITCHTIP_DOMAIN"].split("://", 1)[1].rstrip("/")
            oidc_server_url = os.environ["OIDC_SERVER_URL"]

            User = get_user_model()
            user, _ = User.objects.get_or_create(
                username=username,
                defaults={"email": email, "is_staff": True, "is_superuser": True},
            )
            user.email = email
            user.is_staff = True
            user.is_superuser = True
            user.set_password(password)
            user.save()

            site, _ = Site.objects.update_or_create(
                pk=1,
                defaults={"domain": site_domain, "name": "GlitchTip"},
            )

            app, _ = SocialApp.objects.update_or_create(
                provider="openid_connect",
                provider_id="keycloak",
                defaults={
                    "name": "Keycloak",
                    "client_id": os.environ["OIDC_CLIENT_ID"],
                    "secret": os.environ["OIDC_CLIENT_SECRET"],
                    "settings": {
                        "server_url": oidc_server_url,
                    },
                },
            )
            app.sites.set([site])
            PY
          EOF
          ]

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          env {
            name  = "OIDC_SERVER_URL"
            value = local.oidc_server_url
          }

          env_from {
            secret_ref {
              name = "glitchtip-secrets"
            }
          }

          env_from {
            secret_ref {
              name = "glitchtip-oidc-secret"
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "256Mi"
            }
          }
        }

        container {
          name  = local.app_name
          image = "glitchtip/glitchtip:${var.image_tag}"

          port {
            container_port = 8000
            name           = "http"
          }

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          env_from {
            secret_ref {
              name = "glitchtip-secrets"
            }
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/code/uploads"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.uploads.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.uploads]
}
