job "gitlab" {

  group "gitlab" {

    # Pin to Hestia - primary GlusterFS node, reduces stale handle issues
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "Hestia"
    }

    network {
      mode = "bridge"
      port "http" {
        to = 80
      }
      port "https" {
        to = 443
      }
      port "ssh" {
        to     = 22
        static = 2222
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "gitlab" {
      driver = "docker"

      config {
        image      = "gitlab/gitlab-ce:18.8.0-ce.0"
        ports      = ["http", "https", "ssh"]
        shm_size   = 256 * 1024 * 1024 # 256MB for shared memory
        privileged = true
      }

      volume_mount {
        volume      = "gitlab_config"
        destination = "/etc/gitlab"
      }

      volume_mount {
        volume      = "gitlab_data"
        destination = "/var/opt/gitlab"
      }

      template {
        data        = <<-EOT
{{ with secret "nomad/default/gitlab" }}
GITLAB_DB_PASSWORD={{ .Data.data.db_password }}
{{ end }}
EOT
        destination = "secrets/gitlab.env"
        env         = true
      }

      env {
        GITLAB_OMNIBUS_CONFIG = <<-EOF
external_url 'https://git.brmartin.co.uk'
nginx['listen_port'] = 80
nginx['listen_https'] = false
nginx['proxy_set_headers'] = {
  "X-Forwarded-Proto" => "https",
  "X-Forwarded-Ssl" => "on"
}
gitlab_rails['gitlab_shell_ssh_port'] = 2222
letsencrypt['enable'] = false

# Registry - listen on port 80, GitLab nginx routes by Host header
registry_external_url 'https://registry.brmartin.co.uk'
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

# Disable bundled PostgreSQL - use external server
postgresql['enable'] = false
gitlab_rails['db_adapter'] = 'postgresql'
gitlab_rails['db_encoding'] = 'unicode'
gitlab_rails['db_host'] = '192.168.1.10'
gitlab_rails['db_port'] = 5433
gitlab_rails['db_database'] = 'gitlabhq_production'
gitlab_rails['db_username'] = 'gitlab'
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

      resources {
        cpu        = 1000
        memory     = 3072
        memory_max = 6144
      }
    }

    service {
      name     = "gitlab"
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      # GitLab readiness check - confirms app is ready to serve requests
      check {
        name     = "gitlab-ready"
        type     = "http"
        path     = "/-/readiness"
        interval = "30s"
        timeout  = "10s"
        expose   = true
      }

      # GitLab liveness check - confirms app is alive
      check {
        name      = "gitlab-alive"
        type      = "http"
        path      = "/-/liveness"
        interval  = "30s"
        timeout   = "5s"
        expose    = true
        on_update = "ignore"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
            }
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {
              exclude_outbound_ports = [5433]
            }
          }
        }
      }

      tags = [
        "traefik.enable=true",
        # Route both gitlab and registry through the same Connect service
        "traefik.http.routers.gitlab.rule=Host(`git.brmartin.co.uk`)",
        "traefik.http.routers.gitlab.entrypoints=websecure",
        "traefik.http.routers.gitlab-registry.rule=Host(`registry.brmartin.co.uk`)",
        "traefik.http.routers.gitlab-registry.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    # Registry service for health checks/discovery only 
    # Routing handled by gitlab service tags above - both hosts go to port 80
    service {
      name     = "gitlab-registry"
      provider = "consul"
      port     = "http"
    }

    # Host volumes - direct GlusterFS FUSE mount, avoids NFS stale file handle issues
    volume "gitlab_config" {
      type      = "host"
      read_only = false
      source    = "gitlab_config"
    }

    volume "gitlab_data" {
      type      = "host"
      read_only = false
      source    = "gitlab_data"
    }
  }
}
