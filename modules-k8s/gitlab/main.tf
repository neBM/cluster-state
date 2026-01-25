# GitLab CE - Multi-Container Architecture (CNG)
#
# Components:
# - Webservice (Rails/Puma) - Main application server
# - Workhorse - Smart reverse proxy, handles git operations
# - Sidekiq - Background job processor
# - Gitaly - Git RPC service
# - Redis - Cache and job queue
# - Registry - Container registry
#
# External dependencies:
# - PostgreSQL on 192.168.1.10:5433
# - Traefik for ingress
#
# Storage:
# - PVCs with glusterfs-nfs StorageClass
# - All containers run as UID 1000 (git user)

locals {
  gitlab_labels = {
    app = "gitlab"
  }

  # Component-specific labels
  webservice_labels = merge(local.gitlab_labels, { component = "webservice" })
  workhorse_labels  = merge(local.gitlab_labels, { component = "workhorse" })
  sidekiq_labels    = merge(local.gitlab_labels, { component = "sidekiq" })
  gitaly_labels     = merge(local.gitlab_labels, { component = "gitaly" })
  redis_labels      = merge(local.gitlab_labels, { component = "redis" })
  registry_labels   = merge(local.gitlab_labels, { component = "registry" })
}

# =============================================================================
# Persistent Volume Claims
# =============================================================================

resource "kubernetes_persistent_volume_claim" "repositories" {
  metadata {
    name      = "gitlab-repositories"
    namespace = var.namespace
    annotations = {
      "volume-name" = "gitlab_repositories"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "uploads" {
  metadata {
    name      = "gitlab-uploads"
    namespace = var.namespace
    annotations = {
      "volume-name" = "gitlab_uploads"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "shared" {
  metadata {
    name      = "gitlab-shared"
    namespace = var.namespace
    annotations = {
      "volume-name" = "gitlab_shared"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "registry" {
  metadata {
    name      = "gitlab-registry"
    namespace = var.namespace
    annotations = {
      "volume-name" = "gitlab_registry"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

# =============================================================================
# ConfigMaps
# =============================================================================

# GitLab Rails configuration templates
resource "kubernetes_config_map" "gitlab_config" {
  metadata {
    name      = "gitlab-config-templates"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  data = {
    "gitlab.yml" = <<-EOF
production:
  gitlab:
    host: ${var.gitlab_hostname}
    port: 443
    https: true
    ssh_host: ${var.gitlab_hostname}
    ssh_port: ${var.ssh_port}
    relative_url_root: ""
    email_enabled: true
    email_from: gitlab@brmartin.co.uk
    email_display_name: GitLab
    email_reply_to: noreply@brmartin.co.uk
    default_theme: 2
    default_projects_features:
      issues: true
      merge_requests: true
      wiki: true
      snippets: true
      builds: true
      container_registry: true
    trusted_proxies:
      - "127.0.0.0/8"
      - "::1/128"
      - "10.42.0.0/16"
      - "10.43.0.0/16"
    time_zone: "Europe/London"
    
  artifacts:
    enabled: true
    path: /srv/gitlab/shared/artifacts
    
  lfs:
    enabled: true
    storage_path: /srv/gitlab/shared/lfs-objects
    
  uploads:
    storage_path: /srv/gitlab/public/uploads
    
  repositories:
    storages:
      default:
        path: /srv/gitlab/shared
        gitaly_address: tcp://gitlab-gitaly:8075
        
  gitaly:
    client_path: /usr/local/bin
    token: ""
    
  gitlab_shell:
    path: /srv/gitlab/gitlab-shell
    hooks_path: /srv/gitlab/gitlab-shell/hooks
    secret_file: /etc/gitlab/gitlab-shell/.gitlab_shell_secret
    ssh_port: ${var.ssh_port}
    
  workhorse:
    secret_file: /etc/gitlab/gitlab-workhorse/secret
    
  registry:
    enabled: true
    host: ${var.registry_hostname}
    port: 443
    api_url: http://gitlab-registry:5000
    issuer: gitlab-issuer
    key: /etc/gitlab/registry/gitlab-registry.key
    
  pages:
    enabled: false
    
  mattermost:
    enabled: false
    
  gravatar:
    enabled: true
    
  cron_jobs:
    stuck_ci_jobs_worker:
      cron: "0 * * * *"
    pipeline_schedule_worker:
      cron: "19 * * * *"
    expire_build_artifacts_worker:
      cron: "50 * * * *"
    repository_archive_cache_worker:
      cron: "0 * * * *"
    repository_check_worker:
      cron: "20 * * * *"
    admin_email_worker:
      cron: "0 0 * * 0"
      
  monitoring:
    ip_whitelist:
      - "127.0.0.0/8"
      - "::1/128"
      - "10.42.0.0/16"
      - "10.43.0.0/16"
    sidekiq_exporter:
      enabled: true
      address: 0.0.0.0
      port: 8082
EOF

    "database.yml" = <<-EOF
production:
  main:
    adapter: postgresql
    encoding: unicode
    database: ${var.db_name}
    host: ${var.db_host}
    port: ${var.db_port}
    username: ${var.db_user}
    password: "<%= File.read('/etc/gitlab/postgres/password').strip %>"
    pool: 10
    prepared_statements: false
  ci:
    adapter: postgresql
    encoding: unicode
    database: ${var.db_name}
    host: ${var.db_host}
    port: ${var.db_port}
    username: ${var.db_user}
    password: "<%= File.read('/etc/gitlab/postgres/password').strip %>"
    pool: 10
    prepared_statements: false
    database_tasks: false
EOF

    "resque.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379
EOF

    "cable.yml" = <<-EOF
production:
  adapter: redis
  url: redis://gitlab-redis:6379
EOF

    "redis.cache.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379/1
EOF

    "redis.queues.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379/2
EOF

    "redis.shared_state.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379/3
EOF

    "redis.trace_chunks.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379/4
EOF

    "redis.rate_limiting.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379/5
EOF

    "redis.sessions.yml" = <<-EOF
production:
  url: redis://gitlab-redis:6379/6
EOF
  }
}

# Gitaly configuration
resource "kubernetes_config_map" "gitaly_config" {
  metadata {
    name      = "gitaly-config"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  data = {
    "config.toml" = <<-EOF
# Gitaly configuration for CNG deployment
bin_dir = "/usr/local/bin"
runtime_dir = "/home/git"

# TCP listener for inter-component communication
listen_addr = "0.0.0.0:8075"

# Prometheus metrics
prometheus_listen_addr = "0.0.0.0:9236"

[[storage]]
name = "default"
path = "/home/git/repositories"

[auth]
# Token read from environment variable GITALY_TOKEN
token = ""

[gitlab]
url = "http://gitlab-webservice:8080"
secret_file = "/etc/gitlab/gitlab-shell/.gitlab_shell_secret"

[gitlab-shell]
dir = "/srv/gitlab-shell"

[hooks]
custom_hooks_dir = "/home/git/repositories/hooks"

[logging]
format = "json"
level = "warn"

[git]
use_bundled_binaries = true
EOF
  }
}

# Workhorse configuration
resource "kubernetes_config_map" "workhorse_config" {
  metadata {
    name      = "workhorse-config"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  data = {
    "workhorse-config.toml" = <<-EOF
# GitLab Workhorse configuration
[redis]
URL = "redis://gitlab-redis:6379"

[[listeners]]
network = "tcp"
addr = "0.0.0.0:8181"
EOF
  }
}

# Registry configuration
resource "kubernetes_config_map" "registry_config" {
  metadata {
    name      = "gitlab-registry-config"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  data = {
    "config.yml" = <<-EOF
version: 0.1
log:
  level: warn
  formatter: json
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
  cache:
    blobdescriptor: inmemory
http:
  addr: 0.0.0.0:5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
auth:
  token:
    realm: https://${var.gitlab_hostname}/jwt/auth
    service: container_registry
    issuer: gitlab-issuer
    rootcertbundle: /etc/docker/registry/certs/gitlab-registry.crt
EOF
  }
}

# =============================================================================
# Redis Deployment and Service
# =============================================================================

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "gitlab-redis"
    namespace = var.namespace
    labels    = local.redis_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.redis_labels
    }

    template {
      metadata {
        labels = local.redis_labels
      }

      spec {
        container {
          name  = "redis"
          image = var.redis_image

          port {
            name           = "redis"
            container_port = 6379
          }

          # Redis args: disable persistence (avoid GlusterFS issues)
          args = ["--save", "", "--appendonly", "no"]

          resources {
            requests = {
              cpu    = var.redis_cpu_request
              memory = var.redis_memory_request
            }
            limits = {
              memory = var.redis_memory_limit
            }
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "gitlab-redis"
    namespace = var.namespace
    labels    = local.redis_labels
  }

  spec {
    selector = local.redis_labels

    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
  }
}

# =============================================================================
# Gitaly Deployment and Service
# =============================================================================

resource "kubernetes_deployment" "gitaly" {
  metadata {
    name      = "gitlab-gitaly"
    namespace = var.namespace
    labels    = local.gitaly_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.gitaly_labels
    }

    template {
      metadata {
        labels = local.gitaly_labels
      }

      spec {
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        container {
          name  = "gitaly"
          image = "${var.gitaly_image}:${var.gitlab_version}"

          port {
            name           = "grpc"
            container_port = 8075
          }

          port {
            name           = "metrics"
            container_port = 9236
          }

          env {
            name  = "GITALY_CONFIG_FILE"
            value = "/etc/gitaly/config.toml"
          }

          env {
            name = "GITALY_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-gitaly"
                key  = "token"
              }
            }
          }

          volume_mount {
            name       = "gitaly-config"
            mount_path = "/etc/gitaly"
          }

          volume_mount {
            name       = "repositories"
            mount_path = "/home/git/repositories"
          }

          volume_mount {
            name       = "shell-secret"
            mount_path = "/etc/gitlab/gitlab-shell"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.gitaly_cpu_request
              memory = var.gitaly_memory_request
            }
            limits = {
              memory = var.gitaly_memory_limit
            }
          }

          readiness_probe {
            tcp_socket {
              port = 8075
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = 8075
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "gitaly-config"
          config_map {
            name = kubernetes_config_map.gitaly_config.metadata[0].name
          }
        }

        volume {
          name = "repositories"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.repositories.metadata[0].name
          }
        }

        volume {
          name = "shell-secret"
          secret {
            secret_name = "gitlab-shell"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.gitaly_config,
    kubernetes_persistent_volume_claim.repositories,
  ]
}

resource "kubernetes_service" "gitaly" {
  metadata {
    name      = "gitlab-gitaly"
    namespace = var.namespace
    labels    = local.gitaly_labels
  }

  spec {
    selector = local.gitaly_labels

    port {
      name        = "grpc"
      port        = 8075
      target_port = 8075
    }

    port {
      name        = "metrics"
      port        = 9236
      target_port = 9236
    }
  }
}

# =============================================================================
# Webservice Deployment and Service
# =============================================================================

resource "kubernetes_deployment" "webservice" {
  metadata {
    name      = "gitlab-webservice"
    namespace = var.namespace
    labels    = local.webservice_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.webservice_labels
    }

    template {
      metadata {
        labels = local.webservice_labels
      }

      spec {
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        container {
          name  = "webservice"
          image = "${var.webservice_image}:${var.gitlab_version}"

          port {
            name           = "http"
            container_port = 8080
          }

          port {
            name           = "metrics"
            container_port = 8082
          }

          env {
            name  = "CONFIG_TEMPLATE_DIRECTORY"
            value = "/var/opt/gitlab/config/templates"
          }

          env {
            name  = "CONFIG_DIRECTORY"
            value = "/srv/gitlab/config"
          }

          env {
            name  = "GITLAB_WEBSERVER"
            value = "puma"
          }

          env {
            name  = "GITLAB_HOST"
            value = var.gitlab_hostname
          }

          env {
            name  = "GITLAB_PORT"
            value = "443"
          }

          env {
            name  = "GITLAB_HTTPS"
            value = "true"
          }

          env {
            name  = "ENABLE_BOOTSNAP"
            value = "1"
          }

          env {
            name  = "ACTION_CABLE_IN_APP"
            value = "true"
          }

          env {
            name  = "PUMA_WORKERS"
            value = "0"
          }

          env {
            name  = "PUMA_THREADS_MIN"
            value = "1"
          }

          env {
            name  = "PUMA_THREADS_MAX"
            value = "4"
          }

          env {
            name = "GITALY_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-gitaly"
                key  = "token"
              }
            }
          }

          volume_mount {
            name       = "config-templates"
            mount_path = "/var/opt/gitlab/config/templates"
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/srv/gitlab/public/uploads"
          }

          volume_mount {
            name       = "shared"
            mount_path = "/srv/gitlab/shared"
          }

          volume_mount {
            name       = "db-password"
            mount_path = "/etc/gitlab/postgres"
            read_only  = true
          }

          # Mount secrets.yml directly to Rails config directory
          # CNG reads from /srv/gitlab/config/secrets.yml (hardcoded in initializers/2_secret_token.rb)
          volume_mount {
            name       = "rails-secret"
            mount_path = "/srv/gitlab/config/secrets.yml"
            sub_path   = "secrets.yml"
            read_only  = true
          }

          volume_mount {
            name       = "workhorse-secret"
            mount_path = "/etc/gitlab/gitlab-workhorse"
            read_only  = true
          }

          volume_mount {
            name       = "shell-secret"
            mount_path = "/etc/gitlab/gitlab-shell"
            read_only  = true
          }

          volume_mount {
            name       = "registry-auth"
            mount_path = "/etc/gitlab/registry"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.webservice_cpu_request
              memory = var.webservice_memory_request
            }
            limits = {
              memory = var.webservice_memory_limit
            }
          }

          # Rails takes a long time to boot
          startup_probe {
            http_get {
              path = "/-/readiness"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30
          }

          readiness_probe {
            http_get {
              path = "/-/readiness"
              port = 8080
            }
            initial_delay_seconds = 0
            period_seconds        = 30
            timeout_seconds       = 10
          }

          liveness_probe {
            http_get {
              path = "/-/liveness"
              port = 8080
            }
            initial_delay_seconds = 0
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "config-templates"
          config_map {
            name = kubernetes_config_map.gitlab_config.metadata[0].name
          }
        }

        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.uploads.metadata[0].name
          }
        }

        volume {
          name = "shared"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.shared.metadata[0].name
          }
        }

        volume {
          name = "db-password"
          secret {
            secret_name = "gitlab-secrets"
            items {
              key  = "db_password"
              path = "password"
            }
          }
        }

        volume {
          name = "rails-secret"
          secret {
            secret_name = "gitlab-rails-secret"
          }
        }

        volume {
          name = "workhorse-secret"
          secret {
            secret_name = "gitlab-workhorse"
          }
        }

        volume {
          name = "shell-secret"
          secret {
            secret_name = "gitlab-shell"
          }
        }

        volume {
          name = "registry-auth"
          secret {
            secret_name = "gitlab-registry-auth"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.redis,
    kubernetes_deployment.gitaly,
    kubernetes_config_map.gitlab_config,
    kubernetes_persistent_volume_claim.uploads,
    kubernetes_persistent_volume_claim.shared,
  ]
}

resource "kubernetes_service" "webservice" {
  metadata {
    name      = "gitlab-webservice"
    namespace = var.namespace
    labels    = local.webservice_labels
  }

  spec {
    selector = local.webservice_labels

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }

    port {
      name        = "metrics"
      port        = 8082
      target_port = 8082
    }
  }
}

# =============================================================================
# Workhorse Deployment and Service
# =============================================================================

resource "kubernetes_deployment" "workhorse" {
  metadata {
    name      = "gitlab-workhorse"
    namespace = var.namespace
    labels    = local.workhorse_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.workhorse_labels
    }

    template {
      metadata {
        labels = local.workhorse_labels
      }

      spec {
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        container {
          name  = "workhorse"
          image = "${var.workhorse_image}:${var.gitlab_version}"

          port {
            name           = "http"
            container_port = 8181
          }

          env {
            name  = "CONFIG_TEMPLATE_DIRECTORY"
            value = "/var/opt/gitlab/config/templates"
          }

          env {
            name  = "CONFIG_DIRECTORY"
            value = "/srv/gitlab/config"
          }

          env {
            name  = "GITLAB_WORKHORSE_EXTRA_ARGS"
            value = "-authBackend http://gitlab-webservice:8080 -cableBackend http://gitlab-webservice:8080"
          }

          volume_mount {
            name       = "workhorse-config"
            mount_path = "/var/opt/gitlab/config/templates"
          }

          volume_mount {
            name       = "workhorse-secret"
            mount_path = "/etc/gitlab/gitlab-workhorse"
            read_only  = true
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/srv/gitlab/public/uploads"
          }

          volume_mount {
            name       = "shared"
            mount_path = "/srv/gitlab/shared"
          }

          resources {
            requests = {
              cpu    = var.workhorse_cpu_request
              memory = var.workhorse_memory_request
            }
            limits = {
              memory = var.workhorse_memory_limit
            }
          }

          readiness_probe {
            http_get {
              path = "/-/readiness"
              port = 8181
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/-/liveness"
              port = 8181
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "workhorse-config"
          config_map {
            name = kubernetes_config_map.workhorse_config.metadata[0].name
          }
        }

        volume {
          name = "workhorse-secret"
          secret {
            secret_name = "gitlab-workhorse"
          }
        }

        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.uploads.metadata[0].name
          }
        }

        volume {
          name = "shared"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.shared.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.webservice,
    kubernetes_config_map.workhorse_config,
  ]
}

resource "kubernetes_service" "workhorse" {
  metadata {
    name      = "gitlab-workhorse"
    namespace = var.namespace
    labels    = local.workhorse_labels
  }

  spec {
    selector = local.workhorse_labels

    port {
      name        = "http"
      port        = 8181
      target_port = 8181
    }
  }
}

# =============================================================================
# Sidekiq Deployment
# =============================================================================

resource "kubernetes_deployment" "sidekiq" {
  metadata {
    name      = "gitlab-sidekiq"
    namespace = var.namespace
    labels    = local.sidekiq_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.sidekiq_labels
    }

    template {
      metadata {
        labels = local.sidekiq_labels
      }

      spec {
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        container {
          name  = "sidekiq"
          image = "${var.sidekiq_image}:${var.gitlab_version}"

          port {
            name           = "metrics"
            container_port = 8082
          }

          env {
            name  = "CONFIG_TEMPLATE_DIRECTORY"
            value = "/var/opt/gitlab/config/templates"
          }

          env {
            name  = "CONFIG_DIRECTORY"
            value = "/srv/gitlab/config"
          }

          env {
            name  = "GITLAB_HOST"
            value = var.gitlab_hostname
          }

          env {
            name  = "GITLAB_PORT"
            value = "443"
          }

          env {
            name  = "GITLAB_HTTPS"
            value = "true"
          }

          env {
            name  = "ENABLE_BOOTSNAP"
            value = "1"
          }

          env {
            name  = "SIDEKIQ_CONCURRENCY"
            value = "5"
          }

          env {
            name = "GITALY_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-gitaly"
                key  = "token"
              }
            }
          }

          volume_mount {
            name       = "config-templates"
            mount_path = "/var/opt/gitlab/config/templates"
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/srv/gitlab/public/uploads"
          }

          volume_mount {
            name       = "shared"
            mount_path = "/srv/gitlab/shared"
          }

          volume_mount {
            name       = "db-password"
            mount_path = "/etc/gitlab/postgres"
            read_only  = true
          }

          # Mount secrets.yml directly to Rails config directory
          # CNG reads from /srv/gitlab/config/secrets.yml (hardcoded in initializers/2_secret_token.rb)
          volume_mount {
            name       = "rails-secret"
            mount_path = "/srv/gitlab/config/secrets.yml"
            sub_path   = "secrets.yml"
            read_only  = true
          }

          volume_mount {
            name       = "shell-secret"
            mount_path = "/etc/gitlab/gitlab-shell"
            read_only  = true
          }

          volume_mount {
            name       = "workhorse-secret"
            mount_path = "/etc/gitlab/gitlab-workhorse"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.sidekiq_cpu_request
              memory = var.sidekiq_memory_request
            }
            limits = {
              memory = var.sidekiq_memory_limit
            }
          }

          # Sidekiq doesn't have HTTP health checks, use process check
          readiness_probe {
            exec {
              command = ["pgrep", "-f", "sidekiq"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          liveness_probe {
            exec {
              command = ["pgrep", "-f", "sidekiq"]
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }
        }

        volume {
          name = "config-templates"
          config_map {
            name = kubernetes_config_map.gitlab_config.metadata[0].name
          }
        }

        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.uploads.metadata[0].name
          }
        }

        volume {
          name = "shared"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.shared.metadata[0].name
          }
        }

        volume {
          name = "db-password"
          secret {
            secret_name = "gitlab-secrets"
            items {
              key  = "db_password"
              path = "password"
            }
          }
        }

        volume {
          name = "rails-secret"
          secret {
            secret_name = "gitlab-rails-secret"
          }
        }

        volume {
          name = "shell-secret"
          secret {
            secret_name = "gitlab-shell"
          }
        }

        volume {
          name = "workhorse-secret"
          secret {
            secret_name = "gitlab-workhorse"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.redis,
    kubernetes_deployment.gitaly,
    kubernetes_config_map.gitlab_config,
  ]
}

# =============================================================================
# Registry Deployment and Service
# =============================================================================

resource "kubernetes_deployment" "registry" {
  metadata {
    name      = "gitlab-registry"
    namespace = var.namespace
    labels    = local.registry_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.registry_labels
    }

    template {
      metadata {
        labels = local.registry_labels
      }

      spec {
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        container {
          name  = "registry"
          image = "${var.registry_image}:${var.gitlab_version}"

          port {
            name           = "http"
            container_port = 5000
          }

          env {
            name  = "REGISTRY_CONFIGURATION_PATH"
            value = "/etc/docker/registry/config.yml"
          }

          volume_mount {
            name       = "registry-config"
            mount_path = "/etc/docker/registry"
          }

          volume_mount {
            name       = "registry-data"
            mount_path = "/var/lib/registry"
          }

          volume_mount {
            name       = "registry-auth"
            mount_path = "/etc/docker/registry/certs"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.registry_cpu_request
              memory = var.registry_memory_request
            }
            limits = {
              memory = var.registry_memory_limit
            }
          }

          # Registry returns 401 on /v2/ without auth, so use TCP probe instead
          readiness_probe {
            tcp_socket {
              port = 5000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = 5000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "registry-config"
          config_map {
            name = kubernetes_config_map.registry_config.metadata[0].name
          }
        }

        volume {
          name = "registry-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.registry.metadata[0].name
          }
        }

        volume {
          name = "registry-auth"
          secret {
            secret_name = "gitlab-registry-auth"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.webservice,
    kubernetes_config_map.registry_config,
    kubernetes_persistent_volume_claim.registry,
  ]
}

resource "kubernetes_service" "registry" {
  metadata {
    name      = "gitlab-registry"
    namespace = var.namespace
    labels    = local.registry_labels
  }

  spec {
    selector = local.registry_labels

    port {
      name        = "http"
      port        = 5000
      target_port = 5000
    }
  }
}

# =============================================================================
# SSH Service - NodePort for external access
# =============================================================================

# Note: SSH access requires GitLab Shell which is embedded in Gitaly
# For now, we'll keep the SSH service but it won't function until
# GitLab Shell is properly configured with the CNG deployment
# TODO: Configure GitLab Shell for SSH access

# =============================================================================
# IngressRoutes
# =============================================================================

# GitLab Web UI - routes to Workhorse (main entry point)
resource "kubectl_manifest" "gitlab_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "gitlab"
      namespace = var.namespace
      labels    = local.gitlab_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.gitlab_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.workhorse.metadata[0].name
              port = 8181
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

# Container Registry
resource "kubectl_manifest" "registry_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "gitlab-registry"
      namespace = var.namespace
      labels    = local.gitlab_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.registry_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.registry.metadata[0].name
              port = 5000
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
