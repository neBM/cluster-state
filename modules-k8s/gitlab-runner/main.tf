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

  # Shared TOML config body used by all runners.
  # CONCURRENT_PLACEHOLDER and RUNNER_NAME_PLACEHOLDER are substituted per-deployment.
  # Credentials (RUNNER_TOKEN_PLACEHOLDER, MINIO_*_PLACEHOLDER) are injected at runtime
  # by the init container so they never appear in ConfigMaps.
  _config_common = <<-EOF
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
    
    # Resource defaults for build containers.
    # No cpu_limit: burstable QoS lets short-lived CI jobs use full node CPU
    # (parallel go build, golangci-lint, eslint, vite build). cpu_request is
    # kept small for scheduling; concurrency caps total pressure per node.
    # Go 1.22+ and golangci-lint read the cgroup cpu.max for GOMAXPROCS /
    # worker count, so removing the limit unblocks their parallelism.
    cpu_request = "100m"
    memory_request = "512Mi"
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
    cleanup_grace_period_seconds = 5
    
    # Pull policy: if-not-present by default, jobs can override
    pull_policy = ["if-not-present"]
    allowed_pull_policies = ["always", "if-not-present", "never"]

    HELPER_IMAGE_LINE_PLACEHOLDER

  # Label every CI job pod so the anti-affinity rule below can find them.
  [runners.kubernetes.pod_labels]
    "ci.brmartin.co.uk/job" = "true"

  # Soft anti-affinity: prefer scheduling each job pod on a node that doesn't
  # already have another CI job pod. Spreads concurrent arm64 jobs across
  # Heracles and Nyx instead of packing onto one. "preferred" (not required)
  # so a single surviving node can still take both jobs if the other is down.
  [runners.kubernetes.affinity]
    [runners.kubernetes.affinity.pod_anti_affinity]
      [[runners.kubernetes.affinity.pod_anti_affinity.preferred_during_scheduling_ignored_during_execution]]
        weight = 100
        [runners.kubernetes.affinity.pod_anti_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term]
          topology_key = "kubernetes.io/hostname"
          [runners.kubernetes.affinity.pod_anti_affinity.preferred_during_scheduling_ignored_during_execution.pod_affinity_term.label_selector]
            match_labels = { "ci.brmartin.co.uk/job" = "true" }

  # Kubedock: minimal Docker API that orchestrates containers as K8s pods.
  # Injected into every job pod so testcontainers "just works" without any
  # per-project CI config. DOCKER_HOST env var above points to this service.
  [[runners.kubernetes.services]]
    name = "joyrex2001/kubedock:0.20.3"
    alias = "kubedock"
    command = ["server", "--port-forward"]

EOF

  # Kubernetes executor config template for arch-specific runners (amd64 / arm64).
  # ARCH_PLACEHOLDER is substituted per-deployment to pin job pods to that arch.
  config_template = join("", [local._config_common, <<-EOF
  # Node selector — pins job pods to the runner's architecture.
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

  # Shared cache via SeaweedFS S3
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
  ])

  # Config template for the any-arch runner.
  # Uses a multi-arch helper image hosted in our registry, assembled from GitLab's
  # arch-specific tags by the infrastructure/gitlab-runner-helper pipeline.
  # containerd on any node resolves the correct variant automatically — no node_selector
  # or arch pinning needed on either the runner process pod or job pods.
  config_template_any = join("", [local._config_common, <<-EOF
  # No node_selector — job pods float to whichever node has available resources.

  # Persistent node-local cache for build tool dependencies (Maven, Gradle, pip, uv, npm)
  [[runners.kubernetes.volumes.host_path]]
    name = "ci-cache"
    mount_path = "/ci-cache"
    host_path = "/var/lib/ci-cache"
    read_only = false

  # Persistent container storage for buildah/podman (base images, layers).
  [[runners.kubernetes.volumes.host_path]]
    name = "containers-storage"
    mount_path = "/var/lib/containers"
    host_path = "/var/lib/ci-containers"
    read_only = false

  # In-cluster registry bypass
  [[runners.kubernetes.volumes.config_map]]
    name = "gitlab-runner-registries-conf"
    mount_path = "/etc/containers/registries.conf"
    sub_path = "registries.conf"
    read_only = true

  # Shared cache via SeaweedFS S3
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
  ])
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
# ConfigMaps for stable runner system IDs
# Persists the runner's .runner_system_id across pod restarts so GitLab
# doesn't accumulate offline manager entries for every pod recreation.
# =============================================================================

resource "kubernetes_config_map" "system_id_amd64" {
  metadata {
    name      = "gitlab-runner-system-id-amd64"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "amd64" })
  }
  data = {
    "system_id" = "r_87qXxf9xnF9v"
  }
}

resource "kubernetes_config_map" "system_id_arm64" {
  metadata {
    name      = "gitlab-runner-system-id-arm64"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "arm64" })
  }
  data = {
    "system_id" = "r_BzDQKMBlN6F3"
  }
}

resource "kubernetes_config_map" "system_id_any" {
  metadata {
    name      = "gitlab-runner-system-id-any"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "any" })
  }
  data = {
    "system_id" = "r_4fRxYMrK4twP"
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
      replace(
        replace(local.config_template, "ARCH_PLACEHOLDER", "amd64"),
        "CONCURRENT_PLACEHOLDER", tostring(var.amd64_concurrent)
      ),
      "HELPER_IMAGE_LINE_PLACEHOLDER", ""
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
      replace(
        replace(local.config_template, "ARCH_PLACEHOLDER", "arm64"),
        "CONCURRENT_PLACEHOLDER", tostring(var.arm64_concurrent)
      ),
      "HELPER_IMAGE_LINE_PLACEHOLDER", ""
    )
  }
}

resource "kubernetes_config_map" "config_template_any" {
  metadata {
    name      = "gitlab-runner-config-template-any"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "any" })
  }

  data = {
    "config.toml.template" = replace(
      replace(
        local.config_template_any,
        "CONCURRENT_PLACEHOLDER", tostring(var.any_concurrent)
      ),
      "HELPER_IMAGE_LINE_PLACEHOLDER",
      "helper_image = \"registry.brmartin.co.uk/infrastructure/gitlab-runner-helper:${var.image_tag}\"\n    image_pull_secrets = [\"gitlab-runner-helper-pull\"]"
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
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-amd64/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" -e \"s/MINIO_ACCESS_KEY_PLACEHOLDER/$MINIO_ACCESS_KEY/\" -e \"s/MINIO_SECRET_KEY_PLACEHOLDER/$MINIO_SECRET_KEY/\" /template/config.toml.template > /config/config.toml && cp /system-id/system_id /config/.runner_system_id"
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

          volume_mount {
            name       = "system-id"
            mount_path = "/system-id"
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
              memory = "64Mi"
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
          name = "system-id"
          config_map {
            name = kubernetes_config_map.system_id_amd64.metadata[0].name
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
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-arm64/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" -e \"s/MINIO_ACCESS_KEY_PLACEHOLDER/$MINIO_ACCESS_KEY/\" -e \"s/MINIO_SECRET_KEY_PLACEHOLDER/$MINIO_SECRET_KEY/\" /template/config.toml.template > /config/config.toml && cp /system-id/system_id /config/.runner_system_id"
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

          volume_mount {
            name       = "system-id"
            mount_path = "/system-id"
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
              memory = "64Mi"
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
          name = "system-id"
          config_map {
            name = kubernetes_config_map.system_id_arm64.metadata[0].name
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
# Any-arch Runner (no node_selector — job pods float to any available node)
# Handles all untagged jobs. The amd64/arm64 runners have run_untagged=false
# in GitLab and only accept jobs explicitly tagged with "amd64" or "arm64".
# =============================================================================

resource "kubernetes_deployment" "runner_any" {
  metadata {
    name      = "gitlab-runner-any"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "any" })
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = merge(local.labels, { arch = "any" })
    }

    template {
      metadata {
        labels = merge(local.labels, { arch = "any" })
      }

      spec {
        service_account_name = kubernetes_service_account.runner.metadata[0].name

        # No node_selector on the runner process pod — let K8s place it anywhere.

        # Init container to generate config from template + secret
        init_container {
          name    = "config-generator"
          image   = "busybox:1.37"
          command = ["/bin/sh", "-c"]
          args = [
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-any/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" -e \"s/MINIO_ACCESS_KEY_PLACEHOLDER/$MINIO_ACCESS_KEY/\" -e \"s/MINIO_SECRET_KEY_PLACEHOLDER/$MINIO_SECRET_KEY/\" /template/config.toml.template > /config/config.toml && cp /system-id/system_id /config/.runner_system_id"
          ]

          env {
            name = "RUNNER_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-runner-secrets"
                key  = "runner_token_any"
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

          volume_mount {
            name       = "system-id"
            mount_path = "/system-id"
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
              memory = "64Mi"
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
            name = kubernetes_config_map.config_template_any.metadata[0].name
          }
        }

        volume {
          name = "system-id"
          config_map {
            name = kubernetes_config_map.system_id_any.metadata[0].name
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
# The secret must exist with keys: runner_token_amd64, runner_token_arm64, runner_token_any
#
# To create/update:
#   kubectl create secret generic gitlab-runner-secrets \
#     --from-literal=runner_token_amd64=glrt-xxx \
#     --from-literal=runner_token_arm64=glrt-yyy \
#     --from-literal=runner_token_any=glrt-zzz \
#     --dry-run=client -o yaml | kubectl apply -f -
