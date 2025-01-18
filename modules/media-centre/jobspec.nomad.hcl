job "media-centre" {
  group "jellyfin" {
    task "jellyfin" {
      user   = "985"
      driver = "docker"

      constraint {
        attribute = "${node.unique.id}"
        value     = "3f6d897a-f755-5677-27c3-e3f0af1dfb7e"
      }

      config {
        image     = "ghcr.io/jellyfin/jellyfin:10.10.3"
        runtime   = "nvidia"
        group_add = ["997"]
        ports     = ["jellyfin"]

        mount {
          type   = "volume"
          target = "/media"
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
          target = "/config"
          source = "jellyfin-config"
        }
      }

      env {
        JELLYFIN_PublishedServerUrl = "https://jellyfin.brmartin.co.uk"
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
      name     = "Jellyfin"
      provider = "consul"
      port     = "jellyfin"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.jellyfin.entrypoints=websecure",
        "traefik.http.routers.jellyfin.rule=Host(`jellyfin.brmartin.co.uk`)"
      ]
    }

    network {
      port "jellyfin" {
        to = 8096
      }
    }
  }

  group "plex" {
    task "plex" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.id}"
        value     = "3f6d897a-f755-5677-27c3-e3f0af1dfb7e"
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
          type   = "volume"
          target = "/transcode"
          source = "plex-transcode"
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
      name     = "Plex"
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
