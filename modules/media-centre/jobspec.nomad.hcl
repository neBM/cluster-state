job "media-centre" {
  group "plex" {
    task "plex" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.name}"
        value     = "Hestia"
      }

      config {
        image   = "plexinc/pms-docker:latest"
        runtime = "nvidia"

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
    }

    network {
      mode = "bridge"
      port "plex" {
        to = 32400
      }
      port "envoy_metrics" {
        to = 9102
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

  group "plex-ingress-group" {

    network {
      mode = "bridge"
      port "inbound" {
        to = 8080
      }
    }

    service {
      port = "inbound"
      tags = [
        "traefik.enable=true",

        "traefik.http.routers.plex.entrypoints=websecure",
        "traefik.http.routers.plex.rule=Host(`plex.brmartin.co.uk`)"
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "media-centre-plex"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }
}
