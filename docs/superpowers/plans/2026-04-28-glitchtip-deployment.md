# GlitchTip Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy GlitchTip at `https://glitchtip.brmartin.co.uk` behind Traefik with Keycloak OIDC, SMTP via the cluster mail relay, external PostgreSQL, shared Valkey, and SeaweedFS-backed uploads.

**Architecture:** Add a dedicated Terraform module that owns the GlitchTip PVC, singleton Deployment, Service, and Traefik Ingress. The pod runs the upstream GlitchTip image in all-in-one mode, with an init container that waits for PostgreSQL, runs migrations, and seeds Django `Site` plus OpenID Connect `SocialApp` records from the existing Kubernetes secrets.

**Tech Stack:** Terraform (`hashicorp/kubernetes`), GlitchTip 6.1.5, Django allauth OpenID Connect, Traefik, SeaweedFS PVCs, PostgreSQL, Docker `psql`

---

## File Map

| Path | Action | Purpose |
|---|---|---|
| `modules-k8s/glitchtip/versions.tf` | Create | Provider requirements for the new module |
| `modules-k8s/glitchtip/variables.tf` | Create | `namespace`, `hostname`, `image_tag` inputs |
| `modules-k8s/glitchtip/main.tf` | Create | PVC, Deployment, Service, Ingress, bootstrap init container |
| `kubernetes.tf` | Modify | Add `module "k8s_glitchtip"` beside the other public services |

---

## Task 1: Scaffold the GlitchTip module interface

**Files:**
- Create: `modules-k8s/glitchtip/versions.tf`
- Create: `modules-k8s/glitchtip/variables.tf`

- [ ] **Step 1: Create `versions.tf` with the Kubernetes provider requirement**

```hcl
# modules-k8s/glitchtip/versions.tf
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}
```

- [ ] **Step 2: Create `variables.tf` with the module inputs**

```hcl
# modules-k8s/glitchtip/variables.tf
variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Public GlitchTip hostname"
  type        = string
  default     = "glitchtip.brmartin.co.uk"
}

variable "image_tag" {
  description = "GlitchTip container image tag"
  type        = string
  # renovate: datasource=docker depName=glitchtip/glitchtip
  default = "6.1.5"
}
```

- [ ] **Step 3: Verify the module skeleton parses**

Run:

```bash
cd modules-k8s/glitchtip
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add modules-k8s/glitchtip/
git commit -m "feat(glitchtip): scaffold module inputs"
```

---

## Task 2: Implement the GlitchTip workload

**Files:**
- Create: `modules-k8s/glitchtip/main.tf`

- [ ] **Step 1: Add the locals, PVC, Service, and Ingress**

Use a single local block for the hostname-derived values and shared env vars, then create the uploads PVC, ClusterIP Service, and Traefik Ingress:

```hcl
# modules-k8s/glitchtip/main.tf
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
```

- [ ] **Step 2: Add the singleton Deployment and main GlitchTip container**

The upstream image runs as UID/GID `5000` and serves on port `8000`, so set the pod `fsGroup` to `5000`, mount the uploads PVC at `/code/uploads`, and use simple HTTP probes against `/`:

```hcl
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

          env_from {
            secret_ref {
              name = "glitchtip-oidc-secret"
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
```

- [ ] **Step 3: Add the bootstrap init container that runs migrations and seeds OIDC**

The init container must be idempotent so it can run on every pod start. It should wait for PostgreSQL by retrying `migrate`, then upsert the Django superuser, the `Site` row, and the OpenID Connect `SocialApp` with `provider_id = "keycloak"`:

```hcl
        init_container {
          name  = "bootstrap"
          image = "glitchtip/glitchtip:${var.image_tag}"

          command = ["/bin/sh", "-ec"]
          args = [<<-EOF
            set -euo pipefail

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
```

- [ ] **Step 4: Run formatting and validation on the module**

Run:

```bash
cd modules-k8s/glitchtip
terraform fmt
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules-k8s/glitchtip/
git commit -m "feat(glitchtip): add deployment, ingress, and bootstrap"
```

---

## Task 3: Wire GlitchTip into the root Terraform config

**Files:**
- Modify: `kubernetes.tf`

- [ ] **Step 1: Add the new module block beside the other public services**

Insert the block after `module "k8s_keycloak"` in the production migrations section so the auth-related services stay grouped together:

```hcl
# GlitchTip - error tracking
# Uses external PostgreSQL on martinibar.lan, shared Valkey, SeaweedFS uploads, and Keycloak OIDC
module "k8s_glitchtip" {
  source = "./modules-k8s/glitchtip"

  namespace = "default"
  hostname  = "glitchtip.brmartin.co.uk"
}
```

- [ ] **Step 2: Run repo-wide format, validate, and plan**

Run:

```bash
set -a && source .env && set +a
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
```

Expected: a plan that adds the new GlitchTip module resources and nothing else.

- [ ] **Step 3: Commit**

```bash
git add kubernetes.tf
git commit -m "feat(k8s): wire in GlitchTip module"
```

---

## Task 4: Prepare the runtime secret and external PostgreSQL database

**Files:**
- None. These are rollout-time prerequisites outside Terraform.

- [ ] **Step 1: Create the external PostgreSQL role and database with a Docker `psql` client**

Use the Docker client the cluster-state repo already relies on for admin access to the external PostgreSQL instance. The role name and database name should both be `glitchtip`:

```bash
docker run --rm -it \
  -e PGPASSWORD='<postgres-admin-password>' \
  postgres:16-alpine \
  psql -h 192.168.1.10 -p 5433 -U postgres -d postgres <<'SQL'
CREATE ROLE glitchtip LOGIN PASSWORD '<glitchtip-db-password>';
CREATE DATABASE glitchtip OWNER glitchtip;
SQL
```

- [ ] **Step 2: Create the runtime Kubernetes secret that GlitchTip will read at startup**

This secret stays out of git. It carries the application secret key, database URL, SMTP URL, and the bootstrap superuser credentials. Replace every placeholder before running it:

```bash
kubectl create secret generic glitchtip-secrets -n default \
  --from-literal=SECRET_KEY='<random-django-secret-key>' \
  --from-literal=DATABASE_URL='postgresql://glitchtip:<glitchtip-db-password>@192.168.1.10:5433/glitchtip?sslmode=disable' \
  --from-literal=EMAIL_URL='smtp+tls://svc-glitchtip:<smtp-password>@mail.brmartin.co.uk:587' \
  --from-literal=DEFAULT_FROM_EMAIL='services@brmartin.co.uk' \
  --from-literal=DJANGO_SUPERUSER_USERNAME='<superuser-username>' \
  --from-literal=DJANGO_SUPERUSER_EMAIL='<superuser-email>' \
  --from-literal=DJANGO_SUPERUSER_PASSWORD='<superuser-password>'
```

If the SMTP password contains `@`, `/`, or `:`, URL-encode it before placing it in `EMAIL_URL`.

- [ ] **Step 3: Confirm the existing OIDC secret is still present**

```bash
kubectl get secret glitchtip-oidc-secret -n default
```

Expected: the secret exists and contains the `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` keys the module expects.

---

## Task 5: Apply the module and verify the service

**Files:**
- None. This is the rollout and smoke-test phase.

- [ ] **Step 1: Apply the saved Terraform plan**

Run:

```bash
set -a && source .env && set +a
terraform apply tfplan
```

- [ ] **Step 2: Wait for the GlitchTip pod to become ready**

Run:

```bash
kubectl rollout status deployment/glitchtip -n default
```

Expected: `deployment "glitchtip" successfully rolled out`

- [ ] **Step 3: Check the init container logs and the live app response**

Run:

```bash
kubectl logs -n default -l app=glitchtip -c bootstrap --tail=200
kubectl logs -n default -l app=glitchtip --tail=200
curl -Ik https://glitchtip.brmartin.co.uk
```

Expected:
- the bootstrap logs show migrations, superuser creation, `Site` upsert, and `SocialApp` upsert
- the main container logs show a clean start
- the HTTP check returns `200` or a valid redirect from the public hostname

- [ ] **Step 4: Confirm the seeded auth objects from inside the pod**

Run:

```bash
POD=$(kubectl get pod -n default -l app=glitchtip -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n default "$POD" -- python manage.py shell -c "from django.contrib.sites.models import Site; from allauth.socialaccount.models import SocialApp; print(Site.objects.get(pk=1).domain); print(SocialApp.objects.get(provider='openid_connect', provider_id='keycloak').name)"
```

Expected output includes `glitchtip.brmartin.co.uk` and `Keycloak`.
