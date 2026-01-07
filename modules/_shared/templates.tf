# Shared template configurations for Nomad jobspecs
# These can be used with templatefile() function in jobspecs

locals {
  # Common NFS mount configuration template
  nfs_mount_config = {
    type = "volume"
    volume_options = {
      driver_config = {
        name = "local"
        options = {
          type   = "nfs"
          o      = "addr=martinibar.lan,nolock,soft,rw"
          device = null # Set in specific module
        }
      }
    }
  }

  # Common environment variables
  common_container_env = {
    TZ = "Europe/London"
  }

  # Common Traefik tag patterns
  traefik_tags_template = {
    enable         = "traefik.enable=true"
    consul_connect = "traefik.consulcatalog.connect=true"
    entrypoint     = "traefik.http.routers.%s.entrypoints=websecure"
    rule           = "traefik.http.routers.%s.rule=Host(`%s`)"
  }

  # Common Consul service configuration
  consul_service_template = {
    provider = "consul"
    connect = {
      sidecar_service = {
        proxy = {
          config = {
            protocol = "http"
          }
          expose = {
            path = {
              path            = "/metrics"
              protocol        = "http"
              local_path_port = 9102
              listener_port   = "envoy_metrics"
            }
          }
          transparent_proxy = {}
        }
      }
    }
  }

  # Common resource profiles
  resource_profiles = {
    micro = {
      cpu        = 50
      memory     = 64
      memory_max = 128
    }
    small = {
      cpu        = 100
      memory     = 128
      memory_max = 256
    }
    medium = {
      cpu        = 200
      memory     = 256
      memory_max = 512
    }
    large = {
      cpu        = 500
      memory     = 512
      memory_max = 1024
    }
    xlarge = {
      cpu        = 1000
      memory     = 1024
      memory_max = 2048
    }
  }

  # Common port configurations
  common_ports = {
    http          = 80
    https         = 443
    plex          = 32400
    envoy_metrics = 9102
  }

  # PostgreSQL connection string template
  postgres_connection = {
    host       = "martinibar.lan"
    port       = "5433"
    ssl_mode   = "disable"
    properties = "?sslmode=disable"
  }
}
