job "homeassistant" {
  group "homeassistant" {

    network {
      port "homeassistant" {
        static = 8123
      }
    }

    task "homeassistant" {
      driver = "docker"

      config {
        image        = "ghcr.io/home-assistant/home-assistant:2025.2.4"
        network_mode = "host"
        privileged   = true

        volumes = [
          "/etc/localtime:/etc/localtime:ro",
          "/run/dbus:/run/dbus:ro"
        ]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }

    volume "config" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_home-assistant_config"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    service {
      port     = "homeassistant"
      provider = "consul"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.homeassistant.entrypoints=websecure",
        "traefik.http.routers.homeassistant.rule=Host(`homeassistant.brmartin.co.uk`)"
      ]
    }
  }
}
