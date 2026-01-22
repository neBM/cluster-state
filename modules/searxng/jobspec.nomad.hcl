job "searxng" {

  group "searxng" {

    network {
      mode = "bridge"
      port "http" {
        to = 8080
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "searxng" {
      driver = "docker"

      config {
        image = "docker.io/searxng/searxng:2025.11.1-0245327fc"

        volumes = ["local:/var/cache/searxng"]
      }

      env {
        SEARXNG_BASE_URL   = "https://searx.brmartin.co.uk"
        SEARXNG_VALKEY_URL = "valkey://ollama-valkey.virtual.consul/1"
      }

      resources {
        cpu        = 100
        memory     = 120
        memory_max = 256
      }

      volume_mount {
        volume      = "config"
        destination = "/etc/searxng"
      }
    }

    volume "config" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_searxng_config"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }

    service {
      name     = "searxng"
      provider = "consul"
      port     = 8080

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        type     = "http"
        path     = "/healthz"
        expose   = true
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.searxng.rule=Host(`searx.brmartin.co.uk`)",
        "traefik.http.routers.searxng.entrypoints=websecure",
        "traefik.http.routers.searxng.middlewares=oauth-auth@docker",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }
}
