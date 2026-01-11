job "media-centre" {
  group "plex" {
    constraint {
      attribute = "${node.unique.name}"
      value     = "Hestia"
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

    ephemeral_disk {
      migrate = true
      size    = 1000
      sticky  = true
    }

    volume "config" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_plex_config"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    task "litestream-restore" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image      = "litestream/litestream:0.5"
        entrypoint = ["/bin/sh"]
        args       = [
          "-c",
          <<-EOF
          set -e
          DB_DIR="/alloc/data/Databases"
          CSI_DB_DIR="/csi/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
          mkdir -p "$DB_DIR"

          # Wait for connect-proxy to be ready (60 seconds)
          echo "Waiting for connect-proxy to be ready..."
          sleep 60

          # Try to restore from litestream backup first
          litestream restore -if-db-not-exists -if-replica-exists \
            -config /local/litestream.yml \
            "$DB_DIR/com.plexapp.plugins.library.db" || true

          litestream restore -if-db-not-exists -if-replica-exists \
            -config /local/litestream.yml \
            -replica blobs \
            "$DB_DIR/com.plexapp.plugins.library.blobs.db" || true

          # If database doesn't exist and old CSI database exists, copy it
          if [ ! -f "$DB_DIR/com.plexapp.plugins.library.db" ] && [ -f "$CSI_DB_DIR/com.plexapp.plugins.library.db" ]; then
            echo "No litestream backup found, copying database from CSI volume..."
            cp "$CSI_DB_DIR/com.plexapp.plugins.library.db" "$DB_DIR/com.plexapp.plugins.library.db"
            chmod 666 "$DB_DIR/com.plexapp.plugins.library.db"
            echo "Database copied from CSI volume and permissions fixed"
          fi

          echo "Litestream restore complete"
          EOF
        ]
      }

      template {
        destination = "local/litestream.yml"
        data        = <<-EOF
{{ with secret "nomad/default/media-centre" }}
dbs:
  - path: /alloc/data/Databases/com.plexapp.plugins.library.db
    replicas:
      - name: library
        type: s3
        bucket: plex-litestream
        path: library
        endpoint: http://minio-minio.virtual.consul:9000
        access-key-id: {{ .Data.data.MINIO_ACCESS_KEY }}
        secret-access-key: {{ .Data.data.MINIO_SECRET_KEY }}
        force-path-style: true
  - path: /alloc/data/Databases/com.plexapp.plugins.library.blobs.db
    replicas:
      - name: blobs
        type: s3
        bucket: plex-litestream
        path: blobs
        endpoint: http://minio-minio.virtual.consul:9000
        access-key-id: {{ .Data.data.MINIO_ACCESS_KEY }}
        secret-access-key: {{ .Data.data.MINIO_SECRET_KEY }}
        force-path-style: true
{{ end }}
EOF
      }

      volume_mount {
        volume      = "config"
        destination = "/csi/config"
        read_only   = true
      }

      vault {}

      resources {
        cpu    = 100
        memory = 256
      }
    }

    task "litestream" {
      driver = "docker"

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      config {
        image = "litestream/litestream:0.5"
        args  = ["replicate", "-config", "/local/litestream.yml"]
      }

      template {
        destination = "local/litestream.yml"
        data        = <<-EOF
{{ with secret "nomad/default/media-centre" }}
dbs:
  - path: /alloc/data/Databases/com.plexapp.plugins.library.db
    replicas:
      - name: library
        type: s3
        bucket: plex-litestream
        path: library
        endpoint: http://minio-minio.virtual.consul:9000
        access-key-id: {{ .Data.data.MINIO_ACCESS_KEY }}
        secret-access-key: {{ .Data.data.MINIO_SECRET_KEY }}
        force-path-style: true
        sync-interval: 1s
  - path: /alloc/data/Databases/com.plexapp.plugins.library.blobs.db
    replicas:
      - name: blobs
        type: s3
        bucket: plex-litestream
        path: blobs
        endpoint: http://minio-minio.virtual.consul:9000
        access-key-id: {{ .Data.data.MINIO_ACCESS_KEY }}
        secret-access-key: {{ .Data.data.MINIO_SECRET_KEY }}
        force-path-style: true
        sync-interval: 10s
{{ end }}
EOF
      }

      vault {}

      resources {
        cpu        = 100
        memory     = 256
        memory_max = 512
      }
    }

    task "plex" {
      driver = "docker"

      affinity {
        attribute = "${attr.driver.docker.runtime.nvidia}"
        value     = "true"
        weight    = 100
      }

      config {
        image   = "plexinc/pms-docker:latest"
        runtime = "nvidia"

        devices = [
          {
            host_path = "/dev/dri"
          }
        ]

        volumes = [
          "../alloc/data/Databases:/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases",
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
          type     = "tmpfs"
          target   = "/transcode"
          readonly = false
          tmpfs_options {
            mode = 1023
            size = 3.5e+9
          }
        }
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
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
            upstreams {
              destination_name = "minio-minio"
              local_bind_port  = 9000
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
        image = "ghcr.io/jellyfin/jellyfin:10.11.5"

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
      source          = "glusterfs_jellyfin_config"
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
