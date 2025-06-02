job "n8n" {

  group "n8n" {

    network {
      mode = "bridge"
      port "http" {
        to = 443
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "443"

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

        "traefik.http.routers.n8n.rule=Host(`n8n.brmartin.co.uk`)",
        "traefik.http.routers.n8n.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_n8n_data"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }

    task "n8n" {
      driver = "docker"

      config {
        image = "docker.n8n.io/n8nio/n8n:1.97.0"
      }

      env = {
        DB_TYPE                = "postgresdb"
        DB_POSTGRESDB_DATABASE = "n8n"
        DB_POSTGRESDB_HOST     = "192.168.1.10"
        DB_POSTGRESDB_PORT     = "5433"
        DB_POSTGRESDB_USER     = "n8n"
        DB_POSTGRESDB_SCHEMA   = "n8n"
        N8N_PROTOCOL           = "https"
        N8N_HOST               = "n8n.brmartin.co.uk"
        N8N_PORT               = "443"
      }

      template {
        data = <<-EOF
          {{ with nomadVar "nomad/jobs/n8n/n8n/n8n" }}
          DB_POSTGRESDB_PASSWORD={{.db_password}}
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
        volume      = "data"
        destination = "/home/node/.n8n"
      }
    }
  }
}
