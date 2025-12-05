job "media-centre" {
  group "plex" {
    network {
      mode = "bridge"
      port "plex" {
        to = 32400
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "plex" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.name}"
        value     = "Hestia"
      }

      config {
        image   = "plexinc/pms-docker:latest"
        runtime = "nvidia"

        devices = [
          {
            host_path = "/dev/dri"
          }
        ]

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
            size = 3.5e+9
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
        memory     = 128
        memory_max = 4096
      }
    }

    service {
      provider = "consul"
      port     = "32400"

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

        "traefik.http.routers.plex.entrypoints=websecure",
        "traefik.http.routers.plex.rule=Host(`plex.brmartin.co.uk`)",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }

  group "jellyfin" {

    network {
      mode = "bridge"
      port "jellyfin" {
        to = 8096
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 200
    }

    service {
      provider = "consul"
      port     = "8096"

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

        "traefik.http.routers.jellyfin.entrypoints=websecure",
        "traefik.http.routers.jellyfin.rule=Host(`jellyfin.brmartin.co.uk`)",
        "traefik.consulcatalog.connect=true",
      ]
    }

    task "jellyfin" {
      driver = "docker"

      config {
        image = "ghcr.io/jellyfin/jellyfin:10.11.4"

        group_add = ["997"]

        ports = ["jellyfin"]

        devices = [
          {
            host_path = "/dev/dri"
          }
        ]

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
          type     = "tmpfs"
          target   = "/cache"
          readonly = false
          tmpfs_options {
            mode = 1023
            size = 3.5e+9
          }
        }

        volumes = [
          "../alloc/data/config:/config/config",
          "../alloc/data/data:/config/data",
          "../alloc/data/log:/config/log",
          "../alloc/data/plugins:/config/plugins",
          "../alloc/data/root:/config/root",
        ]
      }

      env {
        JELLYFIN_PublishedServerUrl = "https://jellyfin.brmartin.co.uk"
      }

      resources {
        cpu        = 300
        memory     = 512
        memory_max = 2048
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }
    }

    volume "config" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_jellyfin_config"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }
  }

  group "tautulli" {
    network {
      mode = "bridge"
      port "tautulli" {
        to = 8181
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "tautulli" {
      driver = "docker"

      config {
        image = "ghcr.io/tautulli/tautulli:v2.16.0"
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
      port     = "8181"

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
        "traefik.http.routers.tautulli.entrypoints=websecure",
        "traefik.http.routers.tautulli.rule=Host(`tautulli.brmartin.co.uk`)",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }
}
