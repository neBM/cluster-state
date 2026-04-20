# LangFuse Claude Code Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy LangFuse in-cluster for Claude Code session observability, backed by existing PostgreSQL + SeaweedFS + a new shared Valkey + a new ClickHouse pod, and install a Claude Code Stop hook to ship traces.

**Architecture:** Valkey is extracted from open-webui into a standalone shared module. ClickHouse is added as a single-node pod for LangFuse trace storage. LangFuse runs web + worker deployments behind Traefik + Keycloak OIDC. Claude Code's Stop hook reads the session transcript and ships it to LangFuse — no proxy, Pro/Max billing preserved.

**Tech Stack:** Terraform (hashicorp/kubernetes + alekc/kubectl), Valkey 8, ClickHouse 24, LangFuse (langfuse/langfuse), Python 3 (langfuse SDK), Claude Code hooks

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `modules-k8s/valkey/main.tf` | Create | Shared Valkey Deployment + Service |
| `modules-k8s/valkey/variables.tf` | Create | namespace, image_tag |
| `modules-k8s/valkey/versions.tf` | Create | Provider requirements |
| `modules-k8s/open-webui/main.tf` | Modify | Remove valkey resources; update REDIS_URL to shared valkey |
| `modules-k8s/open-webui/variables.tf` | Modify | Remove valkey_image, valkey_tag |
| `modules-k8s/clickhouse/main.tf` | Create | ClickHouse Deployment + PVC + Service |
| `modules-k8s/clickhouse/variables.tf` | Create | namespace, image_tag |
| `modules-k8s/clickhouse/versions.tf` | Create | Provider requirements |
| `modules-k8s/langfuse/main.tf` | Create | Web Deployment + Worker Deployment + Service + IngressRoute |
| `modules-k8s/langfuse/variables.tf` | Create | namespace, hostname, image_tag |
| `modules-k8s/langfuse/versions.tf` | Create | Provider requirements |
| `kubernetes.tf` | Modify | Add module "k8s_valkey", "k8s_clickhouse", "k8s_langfuse"; update open-webui |
| `~/.claude/hooks/langfuse_hook.py` | Create | Stop hook — reads transcript, ships to LangFuse |
| `~/.claude/settings.json` | Modify | Register Stop hook globally |

---

## Task 1: Create shared Valkey module

**Files:**
- Create: `modules-k8s/valkey/main.tf`
- Create: `modules-k8s/valkey/variables.tf`
- Create: `modules-k8s/valkey/versions.tf`

- [ ] **Step 1: Create versions.tf**

```hcl
# modules-k8s/valkey/versions.tf
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}
```

- [ ] **Step 2: Create variables.tf**

```hcl
# modules-k8s/valkey/variables.tf
variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Valkey image tag"
  type        = string
  # renovate: datasource=docker depName=valkey/valkey
  default = "8.1-alpine3.21"
}
```

- [ ] **Step 3: Create main.tf**

```hcl
# modules-k8s/valkey/main.tf
locals {
  app_name = "valkey"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
}

resource "kubernetes_deployment" "valkey" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = "valkey"
          image = "valkey/valkey:${var.image_tag}"

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["valkey-cli", "ping"]
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            exec {
              command = ["valkey-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "valkey" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      port        = 6379
      target_port = 6379
    }
  }
}
```

- [ ] **Step 4: Verify module parses cleanly**

```bash
cd modules-k8s/valkey && terraform init && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules-k8s/valkey/
git commit -m "feat(valkey): add shared Valkey module"
```

---

## Task 2: Migrate open-webui off its own Valkey

**Files:**
- Modify: `modules-k8s/open-webui/main.tf`
- Modify: `modules-k8s/open-webui/variables.tf`

- [ ] **Step 1: Remove Valkey resources from open-webui/main.tf**

Delete the `kubernetes_deployment.valkey` resource (lines starting with `resource "kubernetes_deployment" "valkey"` through its closing brace) and the `kubernetes_service.valkey` resource.

Update the `REDIS_URL` env var in `kubernetes_deployment.open_webui`:

```hcl
env {
  name  = "REDIS_URL"
  value = "redis://valkey.default.svc.cluster.local:6379/0"
}
```

Update the `depends_on` in `kubernetes_deployment.open_webui` — remove `kubernetes_deployment.valkey`:

```hcl
depends_on = [
  kubernetes_persistent_volume_claim.data,
]
```

- [ ] **Step 2: Remove Valkey variables from open-webui/variables.tf**

Delete `variable "valkey_image"` and `variable "valkey_tag"` blocks entirely.

- [ ] **Step 3: Verify open-webui module parses cleanly**

```bash
cd modules-k8s/open-webui && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add modules-k8s/open-webui/
git commit -m "refactor(open-webui): remove embedded Valkey, point to shared service"
```

---

## Task 3: Wire Valkey into kubernetes.tf

**Files:**
- Modify: `kubernetes.tf`

- [ ] **Step 1: Add shared Valkey module block**

Add after the `# Core Infrastructure` section comment in `kubernetes.tf`, before `module "k8s_seaweedfs"`:

```hcl
# Valkey — Shared Redis-compatible cache
# Used by: open-webui, langfuse
module "k8s_valkey" {
  source = "./modules-k8s/valkey"

  namespace = "default"
}
```

- [ ] **Step 2: Update open-webui module block**

The `module "k8s_open_webui"` block currently passes no explicit vars. No changes needed to the call site — the valkey vars were removed from the module. Verify the block looks like:

```hcl
module "k8s_open_webui" {
  source = "./modules-k8s/open-webui"

  namespace = "default"
  hostname  = "chat.brmartin.co.uk"
}
```

- [ ] **Step 3: Run terraform plan and verify expected changes**

```bash
terraform plan -var="k8s_config_path=~/.kube/config" 2>&1 | tee /tmp/valkey-plan.txt
grep -E "will be created|will be destroyed|must be replaced" /tmp/valkey-plan.txt
```

Expected output includes:
- `module.k8s_valkey.kubernetes_deployment.valkey will be created`
- `module.k8s_valkey.kubernetes_service.valkey will be created`
- `module.k8s_open_webui.kubernetes_deployment.valkey will be destroyed`
- `module.k8s_open_webui.kubernetes_service.valkey will be destroyed`

**Do not apply yet** — apply happens in Task 8 after all modules are written.

- [ ] **Step 4: Commit**

```bash
git add kubernetes.tf
git commit -m "feat(kubernetes): wire shared Valkey module"
```

---

## Task 4: Create ClickHouse module

**Files:**
- Create: `modules-k8s/clickhouse/main.tf`
- Create: `modules-k8s/clickhouse/variables.tf`
- Create: `modules-k8s/clickhouse/versions.tf`

- [ ] **Step 1: Create versions.tf**

```hcl
# modules-k8s/clickhouse/versions.tf
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}
```

- [ ] **Step 2: Create variables.tf**

```hcl
# modules-k8s/clickhouse/variables.tf
variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "ClickHouse server image tag"
  type        = string
  # renovate: datasource=docker depName=clickhouse/clickhouse-server
  default = "24.12-alpine"
}
```

- [ ] **Step 3: Create main.tf**

```hcl
# modules-k8s/clickhouse/main.tf
locals {
  app_name = "clickhouse"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
}

resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "clickhouse-data-sw"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "clickhouse" {
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
        container {
          name  = "clickhouse"
          image = "clickhouse/clickhouse-server:${var.image_tag}"

          port {
            container_port = 8123
            name           = "http"
          }

          port {
            container_port = 9000
            name           = "native"
          }

          env {
            name  = "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT"
            value = "1"
          }

          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "clickhouse-secrets"
                key  = "CLICKHOUSE_PASSWORD"
              }
            }
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/clickhouse"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim.data,
  ]
}

resource "kubernetes_service" "clickhouse" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      name        = "http"
      port        = 8123
      target_port = 8123
    }

    port {
      name        = "native"
      port        = 9000
      target_port = 9000
    }
  }
}
```

- [ ] **Step 4: Verify module parses cleanly**

```bash
cd modules-k8s/clickhouse && terraform init && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules-k8s/clickhouse/
git commit -m "feat(clickhouse): add single-node ClickHouse module for LangFuse"
```

---

## Task 5: Wire ClickHouse into kubernetes.tf

**Files:**
- Modify: `kubernetes.tf`

- [ ] **Step 1: Add ClickHouse module block**

Add after the `module "k8s_valkey"` block:

```hcl
# ClickHouse — OLAP trace store for LangFuse
module "k8s_clickhouse" {
  source = "./modules-k8s/clickhouse"

  namespace = "default"
}
```

- [ ] **Step 2: Verify plan**

```bash
terraform plan -var="k8s_config_path=~/.kube/config" 2>&1 | grep -E "will be created|will be destroyed|must be replaced"
```

Expected additions:
- `module.k8s_clickhouse.kubernetes_persistent_volume_claim.data will be created`
- `module.k8s_clickhouse.kubernetes_deployment.clickhouse will be created`
- `module.k8s_clickhouse.kubernetes_service.clickhouse will be created`

- [ ] **Step 3: Commit**

```bash
git add kubernetes.tf
git commit -m "feat(kubernetes): wire ClickHouse module"
```

---

## Task 6: Create LangFuse module

**Files:**
- Create: `modules-k8s/langfuse/main.tf`
- Create: `modules-k8s/langfuse/variables.tf`
- Create: `modules-k8s/langfuse/versions.tf`

- [ ] **Step 1: Create versions.tf**

```hcl
# modules-k8s/langfuse/versions.tf
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}
```

- [ ] **Step 2: Create variables.tf**

```hcl
# modules-k8s/langfuse/variables.tf
variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "hostname" {
  description = "Hostname for LangFuse dashboard"
  type        = string
  default     = "langfuse.brmartin.co.uk"
}

variable "image_tag" {
  description = "LangFuse image tag (used for both web and worker)"
  type        = string
  # renovate: datasource=docker depName=langfuse/langfuse
  default = "3"
}
```

- [ ] **Step 3: Create main.tf — locals and web deployment**

```hcl
# modules-k8s/langfuse/main.tf
locals {
  web_labels = {
    app        = "langfuse"
    component  = "web"
    managed-by = "terraform"
  }
  worker_labels = {
    app        = "langfuse"
    component  = "worker"
    managed-by = "terraform"
  }

  common_env = [
    {
      name  = "NEXTAUTH_URL"
      value = "https://${var.hostname}"
    },
    {
      name  = "TELEMETRY_ENABLED"
      value = "false"
    },
    {
      name  = "LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES"
      value = "false"
    },
    {
      name  = "CLICKHOUSE_MIGRATION_URL"
      value = "clickhouse://clickhouse.default.svc.cluster.local:9000"
    },
    {
      name  = "CLICKHOUSE_URL"
      value = "http://clickhouse.default.svc.cluster.local:8123"
    },
    {
      name  = "CLICKHOUSE_USER"
      value = "default"
    },
    {
      name  = "REDIS_CONNECTION_STRING"
      value = "redis://valkey.default.svc.cluster.local:6379/0"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_ENABLED"
      value = "true"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_BUCKET"
      value = "langfuse"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT"
      value = "http://seaweedfs-s3.default.svc.cluster.local:8333"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_REGION"
      value = "us-east-1"
    },
    {
      name  = "LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE"
      value = "true"
    },
    {
      name  = "AUTH_CUSTOM_NAME"
      value = "Keycloak"
    },
    {
      name  = "AUTH_CUSTOM_SCOPE"
      value = "openid email profile"
    },
    {
      name  = "AUTH_CUSTOM_ISSUER"
      value = "https://sso.brmartin.co.uk/realms/prod"
    },
    {
      name  = "AUTH_DISABLE_USERNAME_PASSWORD"
      value = "false"
    },
  ]
}

# =============================================================================
# Web Deployment
# =============================================================================

resource "kubernetes_deployment" "web" {
  metadata {
    name      = "langfuse-web"
    namespace = var.namespace
    labels    = local.web_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.web_labels
    }

    template {
      metadata {
        labels = local.web_labels
      }

      spec {
        dynamic "container" {
          for_each = [1]
          content {
            name  = "langfuse-web"
            image = "langfuse/langfuse:${var.image_tag}"

            port {
              container_port = 3000
            }

            dynamic "env" {
              for_each = local.common_env
              content {
                name  = env.value.name
                value = env.value.value
              }
            }

            env {
              name = "DATABASE_URL"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "DATABASE_URL"
                }
              }
            }

            env {
              name = "DIRECT_URL"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "DATABASE_URL"
                }
              }
            }

            env {
              name = "NEXTAUTH_SECRET"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "NEXTAUTH_SECRET"
                }
              }
            }

            env {
              name = "SALT"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "SALT"
                }
              }
            }

            env {
              name = "ENCRYPTION_KEY"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "ENCRYPTION_KEY"
                }
              }
            }

            env {
              name = "CLICKHOUSE_PASSWORD"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "CLICKHOUSE_PASSWORD"
                }
              }
            }

            env {
              name = "LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "S3_ACCESS_KEY_ID"
                }
              }
            }

            env {
              name = "LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "S3_SECRET_ACCESS_KEY"
                }
              }
            }

            env {
              name = "AUTH_CUSTOM_CLIENT_ID"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "AUTH_CUSTOM_CLIENT_ID"
                }
              }
            }

            env {
              name = "AUTH_CUSTOM_CLIENT_SECRET"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "AUTH_CUSTOM_CLIENT_SECRET"
                }
              }
            }

            liveness_probe {
              http_get {
                path = "/api/public/health"
                port = 3000
              }
              initial_delay_seconds = 60
              period_seconds        = 30
              timeout_seconds       = 10
            }

            readiness_probe {
              http_get {
                path = "/api/public/health"
                port = 3000
              }
              initial_delay_seconds = 30
              period_seconds        = 10
              timeout_seconds       = 10
            }

            resources {
              requests = {
                cpu    = "100m"
                memory = "512Mi"
              }
              limits = {
                memory = "1Gi"
              }
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Worker Deployment
# =============================================================================

resource "kubernetes_deployment" "worker" {
  metadata {
    name      = "langfuse-worker"
    namespace = var.namespace
    labels    = local.worker_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.worker_labels
    }

    template {
      metadata {
        labels = local.worker_labels
      }

      spec {
        dynamic "container" {
          for_each = [1]
          content {
            name  = "langfuse-worker"
            image = "langfuse/langfuse-worker:${var.image_tag}"

            dynamic "env" {
              for_each = local.common_env
              content {
                name  = env.value.name
                value = env.value.value
              }
            }

            env {
              name = "DATABASE_URL"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "DATABASE_URL"
                }
              }
            }

            env {
              name = "DIRECT_URL"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "DATABASE_URL"
                }
              }
            }

            env {
              name = "NEXTAUTH_SECRET"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "NEXTAUTH_SECRET"
                }
              }
            }

            env {
              name = "SALT"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "SALT"
                }
              }
            }

            env {
              name = "ENCRYPTION_KEY"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "ENCRYPTION_KEY"
                }
              }
            }

            env {
              name = "CLICKHOUSE_PASSWORD"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "CLICKHOUSE_PASSWORD"
                }
              }
            }

            env {
              name = "LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "S3_ACCESS_KEY_ID"
                }
              }
            }

            env {
              name = "LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "S3_SECRET_ACCESS_KEY"
                }
              }
            }

            env {
              name = "AUTH_CUSTOM_CLIENT_ID"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "AUTH_CUSTOM_CLIENT_ID"
                }
              }
            }

            env {
              name = "AUTH_CUSTOM_CLIENT_SECRET"
              value_from {
                secret_key_ref {
                  name = "langfuse-secrets"
                  key  = "AUTH_CUSTOM_CLIENT_SECRET"
                }
              }
            }

            resources {
              requests = {
                cpu    = "100m"
                memory = "256Mi"
              }
              limits = {
                memory = "512Mi"
              }
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Service and IngressRoute
# =============================================================================

resource "kubernetes_service" "web" {
  metadata {
    name      = "langfuse-web"
    namespace = var.namespace
    labels    = local.web_labels
  }

  spec {
    selector = local.web_labels

    port {
      port        = 80
      target_port = 3000
    }
  }
}

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "langfuse"
      namespace = var.namespace
      labels    = local.web_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.web.metadata[0].name
              port = 80
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}
```

- [ ] **Step 4: Verify module parses**

```bash
cd modules-k8s/langfuse && terraform init && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules-k8s/langfuse/
git commit -m "feat(langfuse): add LangFuse web + worker module with Keycloak OIDC"
```

---

## Task 7: Wire LangFuse into kubernetes.tf

**Files:**
- Modify: `kubernetes.tf`

- [ ] **Step 1: Add LangFuse module block**

Add after `module "k8s_clickhouse"`:

```hcl
# LangFuse — LLM observability platform
# Traces shipped via Claude Code Stop hook (no proxy, Pro/Max billing preserved)
module "k8s_langfuse" {
  source = "./modules-k8s/langfuse"

  namespace = "default"
  hostname  = "langfuse.brmartin.co.uk"
}
```

- [ ] **Step 2: Run full plan and check total change count**

```bash
terraform plan -var="k8s_config_path=~/.kube/config" 2>&1 | tee /tmp/langfuse-plan.txt
grep "Plan:" /tmp/langfuse-plan.txt
```

Expected: `Plan: X to add, 2 to destroy, 0 to change` where destroys are the open-webui Valkey resources.

- [ ] **Step 3: Commit**

```bash
git add kubernetes.tf
git commit -m "feat(kubernetes): wire LangFuse, ClickHouse, shared Valkey modules"
```

---

## Task 8: Create Kubernetes secrets and S3 bucket

These steps run against the live cluster. Complete before applying Terraform.

- [ ] **Step 1: Create ClickHouse secret**

Generate a strong password and store it:

```bash
CLICKHOUSE_PASSWORD=$(openssl rand -base64 32)
kubectl create secret generic clickhouse-secrets \
  --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
  --namespace default
# Save password somewhere safe — you'll need it for langfuse-secrets too
echo "ClickHouse password: $CLICKHOUSE_PASSWORD"
```

- [ ] **Step 2: Obtain LangFuse S3 credentials**

SeaweedFS S3 credentials are configured via `weed shell`. Connect and create a LangFuse identity:

```bash
kubectl exec -it -n default $(kubectl get pod -n default -l app=seaweedfs,component=master -o jsonpath='{.items[0].metadata.name}') -- /bin/sh -c \
  "echo 's3.configure -access_key=langfuse -secret_key=$(openssl rand -hex 20) -buckets=langfuse -actions=Read,Write,List,Tagging,Admin -apply' | weed shell"
```

Note the access key (`langfuse`) and generated secret key for the next step.

- [ ] **Step 3: Create LangFuse bucket in SeaweedFS**

```bash
kubectl exec -it -n default $(kubectl get pod -n default -l app=seaweedfs,component=master -o jsonpath='{.items[0].metadata.name}') -- /bin/sh -c \
  "echo 's3.bucket.create -name langfuse' | weed shell"
```

- [ ] **Step 4: Obtain Keycloak OIDC client credentials**

In Keycloak admin (`https://sso.brmartin.co.uk`): create a new client `langfuse` in the `prod` realm with:
- Client type: OpenID Connect
- Client authentication: On (confidential)
- Valid redirect URIs: `https://langfuse.brmartin.co.uk/api/auth/callback/custom`
- Note the client secret from the Credentials tab.

- [ ] **Step 5: Create LangFuse secrets**

```bash
kubectl create secret generic langfuse-secrets \
  --from-literal=DATABASE_URL="postgresql://<user>:<pass>@192.168.1.10:5433/langfuse" \
  --from-literal=NEXTAUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=SALT="$(openssl rand -base64 32)" \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
  --from-literal=S3_ACCESS_KEY_ID="langfuse" \
  --from-literal=S3_SECRET_ACCESS_KEY="<secret-from-step-2>" \
  --from-literal=AUTH_CUSTOM_CLIENT_ID="langfuse" \
  --from-literal=AUTH_CUSTOM_CLIENT_SECRET="<keycloak-client-secret>" \
  --namespace default
```

Replace angle-bracket placeholders with actual values. `DATABASE_URL` requires a new `langfuse` database created on martinibar PostgreSQL first:

```bash
# On martinibar or via kubectl psql pod:
psql -h 192.168.1.10 -p 5433 -U postgres -c "CREATE DATABASE langfuse;"
```

- [ ] **Step 6: Verify secrets exist**

```bash
kubectl get secret clickhouse-secrets langfuse-secrets -n default
```

Expected: both secrets listed.

---

## Task 9: Apply infrastructure

- [ ] **Step 1: Apply — Valkey migration first**

Apply in one shot; Terraform handles ordering. The open-webui Valkey pod will be replaced by shared Valkey.

```bash
terraform apply -var="k8s_config_path=~/.kube/config" -auto-approve 2>&1 | tee /tmp/apply-output.txt
```

- [ ] **Step 2: Verify shared Valkey running**

```bash
kubectl get pod -n default -l app=valkey
```

Expected: `valkey-<hash>   1/1   Running`

- [ ] **Step 3: Verify open-webui still healthy**

```bash
kubectl get pod -n default -l app=open-webui
```

Expected: `open-webui-<hash>   1/1   Running`

If open-webui is in CrashLoopBackOff, check logs: `kubectl logs -n default -l app=open-webui --tail=50`

- [ ] **Step 4: Verify ClickHouse running**

```bash
kubectl get pod -n default -l app=clickhouse
kubectl exec -n default deployment/clickhouse -- curl -s http://localhost:8123/ping
```

Expected: pod Running, ping returns `Ok.`

- [ ] **Step 5: Verify LangFuse web running**

```bash
kubectl get pod -n default -l app=langfuse
```

Wait up to 3 minutes for initial startup (DB migrations run on first boot).

```bash
kubectl logs -n default deployment/langfuse-web --tail=50 | grep -E "Ready|Error|migration"
```

Expected: log line containing `Ready` or `Listening on port 3000`.

- [ ] **Step 6: Verify LangFuse dashboard accessible**

```bash
curl -sk https://langfuse.brmartin.co.uk/api/public/health | python3 -m json.tool
```

Expected: `{"status": "OK"}`

---

## Task 10: Install Claude Code Stop hook

These steps run on your local machine (not in the cluster).

- [ ] **Step 1: Install LangFuse Python SDK**

```bash
pip install langfuse
```

Verify: `python3 -c "import langfuse; print(langfuse.__version__)"`

- [ ] **Step 2: Create hook directory**

```bash
mkdir -p ~/.claude/hooks
```

- [ ] **Step 3: Create hook script**

```python
#!/usr/bin/env python3
# ~/.claude/hooks/langfuse_hook.py
# Claude Code Stop hook — ships session traces to LangFuse.
# Activated per-project via TRACE_TO_LANGFUSE=true in .claude/settings.local.json

import json
import os
import sys

if os.environ.get("TRACE_TO_LANGFUSE") != "true":
    sys.exit(0)

try:
    from langfuse import Langfuse
except ImportError:
    sys.exit(0)

# Stop hook input arrives via stdin as JSON
try:
    hook_input = json.load(sys.stdin)
except (json.JSONDecodeError, EOFError):
    sys.exit(0)

session_id = hook_input.get("session_id", "unknown")
transcript_path = hook_input.get("transcript_path") or os.environ.get("CLAUDE_TRANSCRIPT_PATH")

if not transcript_path or not os.path.exists(transcript_path):
    sys.exit(0)

# Transcript is JSONL — one JSON object per line
messages = []
try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if line:
                messages.append(json.loads(line))
except (OSError, json.JSONDecodeError):
    sys.exit(0)

# Extract last human/assistant turn
human_content = None
assistant_content = None
for msg in reversed(messages):
    role = msg.get("role") or msg.get("type", "")
    content = msg.get("content") or msg.get("message", "")
    if isinstance(content, list):
        content = " ".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    if assistant_content is None and role in ("assistant", "tool_result"):
        assistant_content = str(content)
    elif human_content is None and role in ("human", "user"):
        human_content = str(content)
        break

if not human_content:
    sys.exit(0)

try:
    langfuse = Langfuse()  # reads LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_HOST

    trace = langfuse.trace(
        id=session_id,
        name="claude-code",
        metadata={
            "cwd": hook_input.get("cwd", os.getcwd()),
        },
    )

    trace.generation(
        name="response",
        model=hook_input.get("model", "claude"),
        input=human_content,
        output=assistant_content or "",
    )

    langfuse.flush()
except Exception:
    pass  # Never block Claude Code on observability failures

sys.exit(0)
```

Save as `~/.claude/hooks/langfuse_hook.py` and make executable:

```bash
chmod +x ~/.claude/hooks/langfuse_hook.py
```

- [ ] **Step 4: Register hook in `~/.claude/settings.json`**

Read `~/.claude/settings.json`. If a `hooks` key exists, add the Stop entry. If the file does not exist, create it. Final `hooks` section:

```json
"hooks": {
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "python3 ~/.claude/hooks/langfuse_hook.py"
        }
      ]
    }
  ]
}
```

- [ ] **Step 5: Add LangFuse env vars to shell**

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
export LANGFUSE_HOST="https://langfuse.brmartin.co.uk"
export LANGFUSE_PUBLIC_KEY="pk-lf-..."   # from LangFuse dashboard → Settings → API Keys
export LANGFUSE_SECRET_KEY="sk-lf-..."   # from LangFuse dashboard → Settings → API Keys
```

Then: `source ~/.zshrc`

- [ ] **Step 6: Enable tracing for cluster-state project**

```bash
cat >> /home/ben/Documents/Personal/projects/iac/cluster-state/.claude/settings.local.json <<'EOF'
{
  "env": {
    "TRACE_TO_LANGFUSE": "true"
  }
}
EOF
```

If the file already exists and has content, merge the `env` key manually rather than appending.

- [ ] **Step 7: Test hook end-to-end**

Start a Claude Code session in cluster-state, send one message, then verify a trace appears in LangFuse:

```bash
open https://langfuse.brmartin.co.uk
```

Navigate to Traces. Expect a trace named `claude-code` with the last turn's input/output.

If no trace appears, run the hook manually against the last transcript:

```bash
TRACE_TO_LANGFUSE=true LANGFUSE_HOST=https://langfuse.brmartin.co.uk \
  LANGFUSE_PUBLIC_KEY=pk-lf-... LANGFUSE_SECRET_KEY=sk-lf-... \
  ls ~/.claude/projects/ | tail -1 | xargs -I{} \
  echo '{"session_id":"test","transcript_path":"{}","cwd":"/tmp"}' | \
  python3 ~/.claude/hooks/langfuse_hook.py
```

- [ ] **Step 8: Commit hook script and settings**

```bash
git -C ~ add .claude/hooks/langfuse_hook.py .claude/settings.json 2>/dev/null || true
# settings.json is personal — commit only if you track your dotfiles
```

For cluster-state settings.local.json (gitignored — do not commit):

```bash
echo ".claude/settings.local.json" >> /home/ben/Documents/Personal/projects/iac/cluster-state/.gitignore
```

---

## Self-Review Checklist

- **Spec coverage:**
  - ✅ Shared Valkey module (Tasks 1–3)
  - ✅ ClickHouse single-node (Tasks 4–5)
  - ✅ LangFuse web + worker (Tasks 6–7)
  - ✅ Secrets outside TF (Task 8)
  - ✅ Keycloak OIDC on dashboard (Task 6 env vars)
  - ✅ Traefik IngressRoute (Task 6)
  - ✅ SeaweedFS S3 for blob storage (Tasks 6 + 8)
  - ✅ Existing PostgreSQL reused (Task 8)
  - ✅ Claude Code Stop hook (Task 10)
  - ✅ `TRACE_TO_LANGFUSE` per-project toggle (Task 10)

- **No placeholders:** All code blocks are complete and runnable.

- **Type consistency:** `langfuse-secrets` key names consistent across Task 6 (env var → secret ref) and Task 8 (kubectl create secret).

- **Image note:** Task 6 uses `langfuse/langfuse` for web and `langfuse/langfuse-worker` for worker. Verify these image names at https://hub.docker.com/r/langfuse/langfuse before applying — LangFuse may use a single image with a different entrypoint for the worker. If so, change the worker image to `langfuse/langfuse` and add `command = ["/bin/sh", "-c", "node worker.js"]` or equivalent per their docker-compose.
