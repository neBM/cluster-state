# GitLab CE - Git repository management, CI/CD, Container Registry
#
# Single Omnibus container with all services bundled:
# - GitLab Rails app (port 80)
# - Container Registry (port 80, different Host header)
# - Git SSH (port 22 -> NodePort 2222)
# - Bundled: Redis, Puma, Gitaly, Workhorse
#
# External PostgreSQL on 192.168.1.10:5433
#
# IMPORTANT: Requires privileged mode and 256MB shared memory
# GlusterFS workarounds: sockets moved to /run (tmpfs)

locals {
  gitlab_labels = {
    app = "gitlab"
  }

  # GitLab Omnibus configuration
  omnibus_config = <<-EOF
external_url 'https://${var.gitlab_hostname}'
nginx['listen_port'] = 80
nginx['listen_https'] = false
nginx['proxy_set_headers'] = {
  "X-Forwarded-Proto" => "https",
  "X-Forwarded-Ssl" => "on"
}
gitlab_rails['gitlab_shell_ssh_port'] = ${var.ssh_port}
letsencrypt['enable'] = false

# Registry - listen on port 80, GitLab nginx routes by Host header
registry_external_url 'https://${var.registry_hostname}'
registry_nginx['listen_port'] = 80
registry_nginx['listen_https'] = false
registry_nginx['proxy_set_headers'] = {
  "X-Forwarded-Proto" => "https",
  "X-Forwarded-Ssl" => "on"
}

# Performance tuning for single user
puma['worker_processes'] = 0
sidekiq['max_concurrency'] = 5
prometheus_monitoring['enable'] = false

# Allow K8s health checks to access monitoring endpoints
gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '::1/128', '10.42.0.0/16', '10.43.0.0/16']

# Reduce log verbosity - only log warnings and errors
gitlab_rails['env'] = {
  'GITLAB_LOG_LEVEL' => 'warn',
  'SIDEKIQ_LOG_ARGUMENTS' => '0'
}

# Disable duplicate access logs (workhorse already logs requests with more detail)
nginx['custom_gitlab_server_config'] = "access_log off;"
registry_nginx['custom_gitlab_server_config'] = "access_log off;"

# Disable bundled PostgreSQL - use external server
postgresql['enable'] = false
gitlab_rails['db_adapter'] = 'postgresql'
gitlab_rails['db_encoding'] = 'unicode'
gitlab_rails['db_host'] = '${var.db_host}'
gitlab_rails['db_port'] = ${var.db_port}
gitlab_rails['db_database'] = '${var.db_name}'
gitlab_rails['db_username'] = '${var.db_user}'
gitlab_rails['db_password'] = ENV['GITLAB_DB_PASSWORD']

# =============================================================================
# GlusterFS Compatibility: Move all sockets and runtime files to /run (tmpfs)
# GlusterFS doesn't support Unix sockets and causes stale file handle errors
# =============================================================================

# Gitaly configuration - socket on tmpfs, storage on GlusterFS
gitaly['configuration'] = {
  runtime_dir: '/run/gitaly',
  socket_path: '/run/gitaly/gitaly.socket',
  storage: [
    {
      name: 'default',
      path: '/var/opt/gitlab/git-data/repositories',
    },
  ],
}

# Tell gitlab-rails where to find Gitaly (replaces git_data_dirs removed in 18.0)
gitlab_rails['gitaly_token'] = ''
gitlab_rails['repositories_storages'] = {
  'default' => {
    'gitaly_address' => 'unix:/run/gitaly/gitaly.socket',
  }
}

# Redis - use TCP only, disable persistence (RDB fails on GlusterFS)
redis['bind'] = '127.0.0.1'
redis['port'] = 6379
redis['unixsocket'] = false
redis['save'] = []
redis['stop_writes_on_bgsave_error'] = false
redis['dir'] = '/run/redis'
gitlab_rails['redis_host'] = '127.0.0.1'
gitlab_rails['redis_port'] = 6379

# Workhorse - use TCP to connect to puma
gitlab_workhorse['listen_network'] = 'tcp'
gitlab_workhorse['listen_addr'] = '127.0.0.1:8181'
gitlab_workhorse['auth_backend'] = 'http://127.0.0.1:8080'
# Move puma socket to /run to avoid GlusterFS stale file handles
puma['socket'] = '/run/gitlab/gitlab.socket'

# ActionCable (if enabled)
gitlab_rails['action_cable_in_app'] = true

# Puma - use TCP instead of Unix socket
puma['listen'] = '127.0.0.1'
puma['port'] = 8080
EOF
}

# =============================================================================
# GitLab Deployment
# =============================================================================

resource "kubernetes_deployment" "gitlab" {
  metadata {
    name      = "gitlab"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # Required for single-writer volumes
    }

    selector {
      match_labels = local.gitlab_labels
    }

    template {
      metadata {
        labels = local.gitlab_labels
      }

      spec {
        # Must run on Hestia for GlusterFS NFS mounts
        node_selector = {
          "kubernetes.io/hostname" = "hestia"
        }

        container {
          name  = "gitlab"
          image = var.gitlab_image

          # GitLab requires privileged mode for various internal operations
          security_context {
            privileged = true
          }

          port {
            name           = "http"
            container_port = 80
          }

          port {
            name           = "ssh"
            container_port = 22
            host_port      = 2222 # Expose on host for external SSH access
          }

          env {
            name  = "GITLAB_OMNIBUS_CONFIG"
            value = local.omnibus_config
          }

          env {
            name = "GITLAB_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "gitlab-secrets"
                key  = "db_password"
              }
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/gitlab"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/opt/gitlab"
          }

          # Shared memory for PostgreSQL and other processes
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              memory = var.memory_limit
            }
          }

          # GitLab takes a very long time to start (Puma boot ~2-3 minutes)
          startup_probe {
            http_get {
              path = "/-/readiness"
              port = 80
              http_header {
                name  = "Host"
                value = var.gitlab_hostname
              }
            }
            initial_delay_seconds = 120 # Wait 2 minutes before first check
            period_seconds        = 15
            timeout_seconds       = 10
            failure_threshold     = 40 # Allow up to 10+ minutes total for startup
          }

          liveness_probe {
            http_get {
              path = "/-/liveness"
              port = 80
              http_header {
                name  = "Host"
                value = var.gitlab_hostname
              }
            }
            initial_delay_seconds = 0
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/-/readiness"
              port = 80
              http_header {
                name  = "Host"
                value = var.gitlab_hostname
              }
            }
            initial_delay_seconds = 0
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          host_path {
            path = var.config_path
            type = "Directory"
          }
        }

        volume {
          name = "data"
          host_path {
            path = var.data_path
            type = "Directory"
          }
        }

        # Shared memory volume (256MB)
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "256Mi"
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

# =============================================================================
# Services
# =============================================================================

# HTTP Service for GitLab and Registry
resource "kubernetes_service" "gitlab" {
  metadata {
    name      = "gitlab"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  spec {
    selector = local.gitlab_labels

    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

# SSH Service - NodePort for external access
# Note: hostPort doesn't work reliably with Cilium CNI, so we use NodePort
# The NodePort will be 30022, and the router should forward external port 2222 -> 30022
resource "kubernetes_service" "gitlab_ssh" {
  metadata {
    name      = "gitlab-ssh"
    namespace = var.namespace
    labels    = local.gitlab_labels
  }

  spec {
    type     = "NodePort"
    selector = local.gitlab_labels

    port {
      name        = "ssh"
      port        = 22
      target_port = 22
      node_port   = 30022
    }
  }
}

# =============================================================================
# IngressRoutes
# =============================================================================

# GitLab Web UI
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
              name = kubernetes_service.gitlab.metadata[0].name
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

# Container Registry (same backend, different hostname)
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
              name = kubernetes_service.gitlab.metadata[0].name
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
