job "monica" {

  group "monica" {

    network {
      mode = "bridge"
      port "http" {
        to = 80
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
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
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.monica.rule=Host(`monica.brmartin.co.uk`)",
        "traefik.http.routers.monica.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    volume "storage" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_monica_storage"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }

    task "monica" {
      driver = "docker"

      config {
        image = "docker.io/library/monica:4.1.2"
      }

      env = {
        DB_HOST     = "martinibar.lan"
        DB_USERNAME = "monica"
      }

      template {
        data = <<-EOF
          {{ with nomadVar "nomad/jobs/monica/monica/monica" }}
          APP_KEY={{.api_key}}
          DB_PASSWORD={{.db_password}}
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      volume_mount {
        volume      = "storage"
        destination = "/var/www/html/storage"
      }
    }
  }
}
