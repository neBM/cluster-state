job "ollama" {

  group "ollama" {

    network {
      mode = "bridge"
      port "api" {
        to = 11434
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 5000
    }

    task "ollama" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.name}"
        value     = "Hestia"
      }

      config {
        image   = "ollama/ollama:latest"
        runtime = "nvidia"

        volumes = [
          "alloc/data/:/root/.ollama"
        ]
      }

      env {
        NVIDIA_DRIVER_CAPABILITIES = "all"
        NVIDIA_VISIBLE_DEVICES     = "all"
      }

      resources {
        cpu    = 100
        memory = 1024
      }
    }

    service {
      provider = "consul"
      port     = "11434"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
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
    }
  }

  group "open-webui" {

    network {
      mode = "bridge"
      port "http" {
        to = 8080
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 200
    }

    task "open-webui" {
      driver = "docker"

      config {
        image      = "ghcr.io/open-webui/open-webui:main"
        force_pull = true

        volumes = [
          "alloc/data/:/app/backend/data"
        ]
      }

      env {
        OLLAMA_BASE_URL = "http://ollama-ollama.virtual.consul"
      }

      resources {
        cpu    = 100
        memory = 1024
      }
    }

    service {
      provider = "consul"
      port     = 8080

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
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
    }
  }

  group "open-webui-ingress-group" {

    network {
      mode = "bridge"
      port "inbound" {
        to = 8080
      }
    }

    service {
      port = "inbound"
      tags = [
        "traefik.enable=true",

        "traefik.http.routers.openwebui.rule=Host(`eos.brmartin.co.uk`)",
        "traefik.http.routers.openwebui.entrypoints=websecure"
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "ollama-open-webui"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }
}
