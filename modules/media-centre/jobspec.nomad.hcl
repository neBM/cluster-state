job "media-centre" {
  group "plex" {
    task "plex" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.name}"
        value     = "Hestia"
      }

      config {
        image        = "plexinc/pms-docker:latest"
        runtime      = "nvidia"
        ports        = ["plex"]
        network_mode = "host"

        mount {
          type   = "volume"
          target = "/data"
          volume_options {
            driver_config {
              name = "local"
              options {
                type   = "nfs"
                o      = "addr=martinibar.lan,nolock,soft,rw"
                device = ":/volume1/docker"
              }
            }
          }
        }

        mount {
          type   = "volume"
          target = "/share"
          volume_options {
            driver_config {
              name = "local"
              options {
                type   = "nfs"
                o      = "addr=martinibar.lan,nolock,soft,rw"
                device = ":/volume1/Share"
              }
            }
          }
        }

        mount {
          type   = "volume"
          target = "/config"
          source = "plex-config"
        }

        mount {
          type     = "tmpfs"
          target   = "/transcode"
          readonly = false
          tmpfs_options {
            mode = 1023
          }
        }
      }

      env {
        TZ                          = "Europe/London"
        CHANGE_CONFIG_DIR_OWNERSHIP = "false"
        PLEX_UID                    = "990"
        PLEX_GID                    = "997"
        NVIDIA_DRIVER_CAPABILITIES  = "all"
        NVIDIA_VISIBLE_DEVICES      = "all"
      }

      resources {
        cpu        = 1200
        memory     = 1024
        memory_max = 4096
      }
    }

    service {
      provider = "consul"
      port     = "plex"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.plex.entrypoints=websecure",
        "traefik.http.routers.plex.rule=Host(`plex.brmartin.co.uk`)"
      ]
    }

    network {
      port "plex" {
        static = 32400
      }
    }
  }

  group "tautulli" {
    task "tautulli" {
      driver = "docker"

      config {
        image = "ghcr.io/tautulli/tautulli:v2.15.1"
        ports = ["tautulli"]

        volumes = [
          "/mnt/docker/downloads/config/tautulli:/config",
        ]
      }

      env {
        PUID = "994"
        PGID = "997"
        TZ   = "Europe/London"
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }

    service {
      provider = "consul"
      port     = "tautulli"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.tautulli.entrypoints=websecure",
        "traefik.http.routers.tautulli.rule=Host(`tautulli.brmartin.co.uk`)"
      ]
    }

    network {
      port "tautulli" {
        to = 8181
      }
    }
  }
}
