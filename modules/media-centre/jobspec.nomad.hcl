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
        args = [
          "-c",
          <<-EOF
          set -e

          DB_DIR="/alloc/data/Databases"
          LIBRARY_DB="$DB_DIR/com.plexapp.plugins.library.db"
          BLOBS_DB="$DB_DIR/com.plexapp.plugins.library.blobs.db"
          mkdir -p "$DB_DIR"

          # Skip if databases already exist (ephemeral disk persisted)
          if [ -f "$LIBRARY_DB" ]; then
            echo "Databases already exist on ephemeral disk, skipping restore"
            exit 0
          fi

          # Wait for sidecar proxy to be ready (needed to reach MinIO)
          echo "Waiting for sidecar proxy..."
          TIMEOUT=60
          ELAPSED=0
          while [ $ELAPSED -lt $TIMEOUT ]; do
            if wget -q --spider http://minio-minio.virtual.consul:9000/minio/health/live 2>/dev/null; then
              echo "MinIO reachable via proxy"
              break
            fi
            sleep 2
            ELAPSED=$((ELAPSED + 2))
          done

          if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "WARNING: Could not reach MinIO, proxy may not be ready"
            echo "Continuing anyway - litestream will retry on failure"
          fi

          # Restore from S3 (MinIO)
          echo "Restoring databases from S3..."
          if litestream restore -config /local/litestream.yml -o "$LIBRARY_DB" "$LIBRARY_DB"; then
            echo "Library database restored successfully"
          else
            echo "ERROR: Failed to restore library database from S3"
            exit 1
          fi

          if litestream restore -config /local/litestream.yml -o "$BLOBS_DB" "$BLOBS_DB"; then
            echo "Blobs database restored successfully"
          else
            echo "WARNING: Failed to restore blobs database (may not exist yet)"
          fi

          chown -R 990:997 "$DB_DIR"
          echo "Restore complete"
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
        sync-interval: 5m
        snapshot-interval: 1h
        retention: 168h
        retention-check-interval: 1h
        part-size: 6MB
        concurrency: 2
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
        sync-interval: 5m
        snapshot-interval: 1h
        retention: 168h
        retention-check-interval: 1h
        part-size: 6MB
        concurrency: 2
{{ end }}
EOF
      }

      vault {}

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }
    }

    task "plex" {
      driver = "docker"

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

      # Plex health endpoint returns 401 for unauthenticated requests
      # but that confirms the server is running
      check {
        name     = "plex-alive"
        type     = "http"
        path     = "/identity"
        interval = "30s"
        timeout  = "5s"
        expose   = true
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
        # Memory for HTTP L7 proxy - peak RSS observed ~70MB
        # Virtual memory can spike to 3GB+ but that's address space, not RAM
        sidecar_task {
          resources {
            cpu        = 250
            memory     = 256
            memory_max = 512
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

      check {
        name     = "jellyfin-alive"
        type     = "http"
        path     = "/health"
        interval = "30s"
        timeout  = "5s"
        expose   = true
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

      check {
        name     = "tautulli-alive"
        type     = "http"
        path     = "/status"
        interval = "30s"
        timeout  = "5s"
        expose   = true
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
