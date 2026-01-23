job "open-webui" {

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

      vault {
        env = false
      }

      config {
        image      = "ghcr.io/open-webui/open-webui:0.7.2"
        force_pull = true
      }

      env {
        # Ollama now runs on K8s, accessible via NodePort
        OLLAMA_BASE_URL             = "http://192.168.1.5:31434"
        ENABLE_OAUTH_SIGNUP         = "true"
        OAUTH_CLIENT_ID             = "open-webui"
        OPENID_PROVIDER_URL         = "https://sso.brmartin.co.uk/realms/prod/.well-known/openid-configuration"
        OAUTH_PROVIDER_NAME         = "Keycloak"
        OPENID_REDIRECT_URI         = "https://chat.brmartin.co.uk/oauth/oidc/callback"
        JWT_EXPIRES_IN              = "1h"
        WEBUI_SESSION_COOKIE_SECURE = "true"
        VECTOR_DB                   = "pgvector"
        REDIS_URL                   = "redis://ollama-valkey.virtual.consul/0"
        CORS_ALLOW_ORIGIN           = "https://chat.brmartin.co.uk"
        RAG_EMBEDDING_ENGINE        = "ollama"
      }


      template {
        data = <<-EOF
      	  {{ with secret "nomad/data/default/open-webui" }}
          OAUTH_CLIENT_SECRET="{{.Data.data.OAUTH_CLIENT_SECRET}}"
          WEBUI_SECRET_KEY="{{.Data.data.WEBUI_SECRET_KEY}}"
          DATABASE_URL="{{.Data.data.DATABASE_URL}}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu        = 100
        memory     = 512
        memory_max = 2048
      }

      volume_mount {
        volume      = "data"
        destination = "/app/backend/data"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_ollama_data"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }

    service {
      name     = "open-webui"
      provider = "consul"
      port     = 8080

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        type     = "http"
        path     = "/health"
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

        "traefik.http.routers.openwebui.rule=Host(`chat.brmartin.co.uk`)",
        "traefik.http.routers.openwebui.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }

  group "valkey" {

    network {
      mode = "bridge"
      port "valkey" {
        to = 6379
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "valkey" {
      driver = "docker"

      config {
        image = "valkey/valkey:9.0.0-alpine3.22"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }

    service {
      name     = "ollama-valkey"
      provider = "consul"
      port     = "6379"

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

  group "postgres" {

    network {
      mode = "bridge"
      port "postgres" {
        to = 5432
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "postgres" {
      driver = "docker"

      vault {
        env = false
      }

      config {
        image = "pgvector/pgvector:pg18"
      }

      # Create openwebui user/database directly - this is a dedicated postgres for Open WebUI
      template {
        data = <<-EOF
          {{ with secret "nomad/data/default/open-webui" }}
          POSTGRES_USER="openwebui"
          POSTGRES_PASSWORD="{{.Data.data.POSTGRES_PASSWORD}}"
          POSTGRES_DB="openwebui"
          {{ end }}
          EOF

        destination = "secrets/postgres.env"
        env         = true
      }

      volume_mount {
        volume      = "postgres_data"
        destination = "/var/lib/postgresql"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }

    service {
      name     = "ollama-postgres"
      provider = "consul"
      port     = "5432"

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

    volume "postgres_data" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_ollama_postgres"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }
  }
}
