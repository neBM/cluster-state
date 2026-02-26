# GitLab Runner - CI/CD job execution (Kubernetes Executor)
#
# Two deployments: amd64 (Hestia) and arm64 (Heracles/Nyx)
# Uses Kubernetes executor - spawns pods for each CI job
# No Docker daemon required on nodes
#
# For container builds, use Podman in CI jobs

locals {
  labels = {
    app        = "gitlab-runner"
    managed-by = "terraform"
  }

  # Kubernetes executor config template
  # ARCH_PLACEHOLDER is replaced per-deployment
  config_template = <<-EOF
concurrent = CONCURRENT_PLACEHOLDER
check_interval = 30
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "RUNNER_NAME_PLACEHOLDER"
  url = "https://git.brmartin.co.uk"
  token = "RUNNER_TOKEN_PLACEHOLDER"
  executor = "kubernetes"
  # Node-local cache env vars — tools find their caches automatically, no .gitlab-ci.yml changes needed
  environment = [
    "MAVEN_USER_HOME=/ci-cache/m2",
    "GRADLE_USER_HOME=/ci-cache/gradle",
    "UV_CACHE_DIR=/ci-cache/uv",
    "PIP_CACHE_DIR=/ci-cache/pip",
    "npm_config_cache=/ci-cache/npm",
    "GOMODCACHE=/ci-cache/gomod",
    "GOCACHE=/ci-cache/gobuild",
    "STORAGE_DRIVER=overlay",
    "DOCKER_HOST=tcp://kubedock:2475",
    "TESTCONTAINERS_RYUK_DISABLED=true",
    "TESTCONTAINERS_CHECKS_DISABLE=true"
  ]
  
  [runners.kubernetes]
    namespace = "${var.job_namespace}"
    service_account = "gitlab-runner"
    image = "alpine:latest"
    privileged = ${var.privileged_jobs}
    
    # Resource defaults for build containers
    cpu_request = "100m"
    memory_request = "512Mi"
    cpu_limit = "2"
    memory_limit = "6Gi"
    
    # Helper container resources
    helper_cpu_request = "50m"
    helper_memory_request = "128Mi"
    helper_cpu_limit = "500m"
    helper_memory_limit = "256Mi"
    
    # Poll settings
    poll_interval = 3
    poll_timeout = 180
    
    # Cleanup
    cleanup_grace_period_seconds = 30
    
    # Pull policy: if-not-present by default, jobs can override
    pull_policy = ["if-not-present"]
    allowed_pull_policies = ["always", "if-not-present", "never"]
    
  # Kubedock: minimal Docker API that orchestrates containers as K8s pods.
  # Injected into every job pod so testcontainers "just works" without any
  # per-project CI config. DOCKER_HOST env var above points to this service.
  [[runners.kubernetes.services]]
    name = "joyrex2001/kubedock:0.20.3"
    alias = "kubedock"
    command = ["server", "--port-forward"]

  # Node selector for arch-specific builds (must be after all kubernetes settings)
  [runners.kubernetes.node_selector]
    "kubernetes.io/arch" = "ARCH_PLACEHOLDER"

  # Persistent node-local cache for build tool dependencies (Maven, Gradle, pip, uv, npm)
  # Avoids zip/upload/download cycle of S3 cache for large, read-heavy dependency trees.
  # Env vars above point each tool at /ci-cache/<tool> — works automatically in all jobs.
  [[runners.kubernetes.volumes.host_path]]
    name = "ci-cache"
    mount_path = "/ci-cache"
    host_path = "/var/lib/ci-cache"
    read_only = false

  # Persistent container storage for buildah/podman (base images, layers).
  # Caches pulled images and intermediate layers locally on each node,
  # avoiding re-pulls from registry on every job.
  [[runners.kubernetes.volumes.host_path]]
    name = "containers-storage"
    mount_path = "/var/lib/containers"
    host_path = "/var/lib/ci-containers"
    read_only = false

  # In-cluster registry bypass: mount registries.conf marking the registry as insecure
  # so buildah uses plain HTTP on :443 when CoreDNS resolves the hostname to the internal service.
  [[runners.kubernetes.volumes.config_map]]
    name = "gitlab-runner-registries-conf"
    mount_path = "/etc/containers/registries.conf"
    sub_path = "registries.conf"
    read_only = true

  # Shared cache via MinIO (S3-compatible)
  [runners.cache]
    Type = "s3"
    Shared = true
    [runners.cache.s3]
      ServerAddress = "${var.cache_s3_endpoint}"
      BucketName = "${var.cache_s3_bucket}"
      Insecure = true
      AuthenticationType = "access-key"
      AccessKey = "MINIO_ACCESS_KEY_PLACEHOLDER"
      SecretKey = "MINIO_SECRET_KEY_PLACEHOLDER"
EOF
}

# =============================================================================
# RBAC - ServiceAccount, Role, RoleBinding
# =============================================================================

resource "kubernetes_service_account" "runner" {
  metadata {
    name      = "gitlab-runner"
    namespace = var.namespace
    labels    = local.labels
  }
}

# Role for the runner to manage job pods
resource "kubernetes_role" "runner" {
  metadata {
    name      = "gitlab-runner"
    namespace = var.job_namespace
    labels    = local.labels
  }

  # Pods - create and manage job pods
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["create", "delete", "get", "list", "watch"]
  }

  # Pod exec/attach/portforward - for running commands in job containers and Kubedock port-forwarding
  rule {
    api_groups = [""]
    resources  = ["pods/exec", "pods/attach", "pods/portforward"]
    verbs      = ["create", "delete", "get", "patch"]
  }

  # Pod logs - for streaming job output
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list"]
  }

  # Secrets - for job variables
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create", "delete", "get", "update"]
  }

  # Services - for CI services and Kubedock testcontainer networking
  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["create", "delete", "get", "list"]
  }

  # ConfigMaps - for Kubedock (single-file volume mounts in testcontainers)
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create", "delete", "get", "list"]
  }

  # ServiceAccounts - for job pods
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["get"]
  }

  # Events - for pod warnings
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_role_binding" "runner" {
  metadata {
    name      = "gitlab-runner"
    namespace = var.job_namespace
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.runner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.runner.metadata[0].name
    namespace = var.namespace
  }
}

# =============================================================================
# ConfigMap for container registries.conf (in-cluster registry bypass)
# =============================================================================

resource "kubernetes_config_map" "registries_conf" {
  count = var.registry_hostname != "" ? 1 : 0

  metadata {
    name      = "gitlab-runner-registries-conf"
    namespace = var.job_namespace
    labels    = local.labels
  }

  data = {
    "registries.conf" = <<-EOF
# In-cluster registry bypass: CoreDNS rewrites ${var.registry_hostname} to the
# internal registry service (port 443 → 5000). The insecure flag makes buildah
# use plain HTTP on :443 instead of TLS, connecting directly to the registry
# pod without Traefik or TLS overhead.
[[registry]]
location = "${var.registry_hostname}"
insecure = true
EOF
  }
}

# =============================================================================
# ConfigMaps for arch-specific config templates
# =============================================================================

resource "kubernetes_config_map" "config_template_amd64" {
  metadata {
    name      = "gitlab-runner-config-template-amd64"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "config.toml.template" = replace(
      replace(local.config_template, "ARCH_PLACEHOLDER", "amd64"),
      "CONCURRENT_PLACEHOLDER", tostring(var.amd64_concurrent)
    )
  }
}

resource "kubernetes_config_map" "config_template_arm64" {
  metadata {
    name      = "gitlab-runner-config-template-arm64"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "config.toml.template" = replace(
      replace(local.config_template, "ARCH_PLACEHOLDER", "arm64"),
      "CONCURRENT_PLACEHOLDER", tostring(var.arm64_concurrent)
    )
  }
}

# =============================================================================
# AMD64 Runner (runs on Hestia, spawns amd64 job pods)
# =============================================================================

resource "kubernetes_deployment" "runner_amd64" {
  metadata {
    name      = "gitlab-runner-amd64"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "amd64" })
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = merge(local.labels, { arch = "amd64" })
    }

    template {
      metadata {
        labels = merge(local.labels, { arch = "amd64" })
      }

      spec {
        service_account_name = kubernetes_service_account.runner.metadata[0].name

        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        # Init container to generate config from template + secret
        init_container {
          name    = "config-generator"
          image   = "busybox:1.37"
          command = ["/bin/sh", "-c"]
          args = [
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-amd64/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" -e \"s/MINIO_ACCESS_KEY_PLACEHOLDER/$MINIO_ACCESS_KEY/\" -e \"s/MINIO_SECRET_KEY_PLACEHOLDER/$MINIO_SECRET_KEY/\" /template/config.toml.template > /config/config.toml"
          ]

          env {
            name = "RUNNER_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-runner-secrets"
                key  = "runner_token_amd64"
              }
            }
          }

          env {
            name = "MINIO_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = var.cache_s3_secret_name
                key  = "accesskey"
              }
            }
          }

          env {
            name = "MINIO_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = var.cache_s3_secret_name
                key  = "secretkey"
              }
            }
          }

          volume_mount {
            name       = "config-template"
            mount_path = "/template"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }

        container {
          name  = "gitlab-runner"
          image = "${var.image}:${var.image_tag}"
          args  = ["run", "--config", "/config/config.toml"]

          volume_mount {
            name       = "config"
            mount_path = "/config"
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
        }

        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.config_template_amd64.metadata[0].name
          }
        }

        volume {
          name = "config"
          empty_dir {}
        }
      }
    }
  }


}

# =============================================================================
# ARM64 Runner (runs on Heracles/Nyx, spawns arm64 job pods)
# =============================================================================

resource "kubernetes_deployment" "runner_arm64" {
  metadata {
    name      = "gitlab-runner-arm64"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "arm64" })
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = merge(local.labels, { arch = "arm64" })
    }

    template {
      metadata {
        labels = merge(local.labels, { arch = "arm64" })
      }

      spec {
        service_account_name = kubernetes_service_account.runner.metadata[0].name

        node_selector = {
          "kubernetes.io/arch" = "arm64"
        }

        # Init container to generate config from template + secret
        init_container {
          name    = "config-generator"
          image   = "busybox:1.37"
          command = ["/bin/sh", "-c"]
          args = [
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-arm64/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" -e \"s/MINIO_ACCESS_KEY_PLACEHOLDER/$MINIO_ACCESS_KEY/\" -e \"s/MINIO_SECRET_KEY_PLACEHOLDER/$MINIO_SECRET_KEY/\" /template/config.toml.template > /config/config.toml"
          ]

          env {
            name = "RUNNER_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-runner-secrets"
                key  = "runner_token_arm64"
              }
            }
          }

          env {
            name = "MINIO_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = var.cache_s3_secret_name
                key  = "accesskey"
              }
            }
          }

          env {
            name = "MINIO_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = var.cache_s3_secret_name
                key  = "secretkey"
              }
            }
          }

          volume_mount {
            name       = "config-template"
            mount_path = "/template"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }

        container {
          name  = "gitlab-runner"
          image = "${var.image}:${var.image_tag}"
          args  = ["run", "--config", "/config/config.toml"]

          volume_mount {
            name       = "config"
            mount_path = "/config"
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
        }

        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.config_template_arm64.metadata[0].name
          }
        }

        volume {
          name = "config"
          empty_dir {}
        }
      }
    }
  }


}

# =============================================================================
# Secret for runner tokens
# =============================================================================
# Note: gitlab-runner-secrets is managed manually (Vault removed 2026-01)
# The secret must exist with keys: runner_token_amd64, runner_token_arm64
#
# To create/update:
#   kubectl create secret generic gitlab-runner-secrets \
#     --from-literal=runner_token_amd64=glrt-xxx \
#     --from-literal=runner_token_arm64=glrt-yyy \
#     --dry-run=client -o yaml | kubectl apply -f -
