job "volts-app" {

  group "volts-app" {

    network {
      mode = "bridge"
      port "http" {
        to = 3000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "volts-app" {
      driver = "docker"

      config {
        image      = "git.brmartin.co.uk/ben/volts-app:main"
        force_pull = true
      }

      resources {
        cpu    = 10
        memory = 400
      }

      env {
        OAUTH_CLIENT_ID       = "volts"
        OAUTH_CLIENT_DISCOVER = "https://sso.brmartin.co.uk/realms/prod/.well-known/openid-configuration"
        PGHOST                = "martinibar.lan"
        PGPORT                = "5433"
        PGUSER                = "volts"
        PGDATABASE            = "volts"
      }

      template {
        data = <<-EOF
          {{ with nomadVar "nomad/jobs/volts-app/volts-app/volts-app" }}
          OAUTH_CLIENT_SECRET={{.OAUTH_CLIENT_SECRET}}
          PGPASSWORD={{.PGPASSWORD}}
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      volume_mount {
        volume      = "data"
        destination = "/app/data"
      }
    }

    service {
      provider = "consul"
      port     = 3000

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

        "traefik.http.routers.volts-app.rule=Host(`volts.brmartin.co.uk`)",
        "traefik.http.routers.volts-app.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_volts-app_data"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }
  }
}
