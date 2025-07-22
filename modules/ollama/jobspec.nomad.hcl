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
      size    = 200
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
          "../alloc/data/:/root/.ollama"
        ]
      }

      env {
        NVIDIA_DRIVER_CAPABILITIES = "all"
        NVIDIA_VISIBLE_DEVICES     = "all"
      }

      resources {
        cpu        = 100
        memory     = 256
        memory_max = 4096
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
            config {
              protocol              = "http"
              local_idle_timeout_ms = 120000
            }
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
      }

      env {
        OLLAMA_BASE_URL = "http://ollama-ollama.virtual.consul"
      }

      resources {
        cpu    = 100
        memory = 1024
      }

      volume_mount {
        volume      = "data"
        destination = "/app/backend/data"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_ollama_data"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
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

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.openwebui.rule=Host(`eos.brmartin.co.uk`)",
        "traefik.http.routers.openwebui.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }

  group "mcpo" {

    network {
      mode = "bridge"
      port "http" {
        to = 8000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "mcpo" {
      driver = "docker"

      config {
        image      = "ghcr.io/open-webui/mcpo:main"
        force_pull = true
        args       = ["--port", "8000", "--config", "${NOMAD_SECRETS_DIR}/config.json"]
      }

      resources {
        cpu    = 100
        memory = 1024
      }

      template {
        data = <<-EOF
          {
            "mcpServers": {
              "memory": {
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-memory"]
              },
              "sequential-thinking": {
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]
              },
              "time": {
                "command": "uvx",
                "args": ["mcp-server-time", "--local-timezone=Europe/London"]
              },
              "brave-search": {
                "command": "npx",
                "args": [
                  "-y",
                  "@modelcontextprotocol/server-brave-search"
                ],
                "env": {
                  "BRAVE_API_KEY": "{{ with nomadVar "nomad/jobs/ollama/mcpo/mcpo" }}{{.BRAVE_API_KEY}}{{ end }}"
                }
              }
            }
          }
          EOF

        destination = "secrets/config.json"
      }
    }

    service {
      provider = "consul"
      port     = 8000

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
}
