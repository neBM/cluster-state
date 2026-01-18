job "vaultwarden" {

  group "vaultwarden" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      name     = "vaultwarden"
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        name     = "vaultwarden-alive"
        type     = "http"
        path     = "/alive"
        interval = "30s"
        timeout  = "5s"
        expose   = true
      }

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.vaultwarden.rule=Host(`bw.brmartin.co.uk`)",
        "traefik.http.routers.vaultwarden.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    task "vaultwarden" {
      driver = "docker"

      vault {}

      config {
        image = "vaultwarden/server:latest"
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      template {
        data = <<-EOF
          {{ with secret "nomad/data/default/vaultwarden" }}
          DATABASE_URL="{{ .Data.data.DATABASE_URL }}"
          SMTP_PASSWORD="{{ .Data.data.SMTP_PASSWORD }}"
          ADMIN_TOKEN="{{ .Data.data.ADMIN_TOKEN }}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      env {
        DOMAIN                  = "https://bw.brmartin.co.uk"
        SIGNUPS_ALLOWED         = "false"
        SMTP_HOST               = "mail.brmartin.co.uk"
        SMTP_FROM               = "services@brmartin.co.uk"
        SMTP_PORT               = "587"
        SMTP_SECURITY           = "starttls"
        SMTP_USERNAME           = "ben@brmartin.co.uk"
        ROCKET_PORT             = "80"
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_vaultwarden_data"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }
  }
}
