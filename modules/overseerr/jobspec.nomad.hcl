job "overseerr" {
  datacenters = ["dc1"]

  group "overseerr" {
    network {
      mode = "bridge"
      port "overseerr" {
        to = 5055
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 200
      sticky  = true
    }

    volume "config" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_overseerr_config"
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

          DB_DIR="/alloc/data/db"
          DB_FILE="$DB_DIR/db.sqlite3"
          mkdir -p "$DB_DIR"

          # Skip if database already exists (ephemeral disk persisted)
          if [ -f "$DB_FILE" ]; then
            echo "Database already exists on ephemeral disk, skipping restore"
            exit 0
          fi

          # Wait for MinIO to be reachable via service mesh
          echo "Waiting for MinIO via service mesh..."
          TIMEOUT=60
          ELAPSED=0
          while [ $ELAPSED -lt $TIMEOUT ]; do
            if wget -q --spider http://minio-minio.virtual.consul/minio/health/live 2>/dev/null; then
              echo "MinIO reachable via mesh"
              break
            fi
            sleep 2
            ELAPSED=$((ELAPSED + 2))
          done

          if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "WARNING: Could not reach MinIO via mesh"
            echo "Continuing anyway - litestream will retry on failure"
          fi

          # Restore from S3 (MinIO)
          echo "Restoring database from S3..."
          
          if litestream restore -config /local/litestream.yml -o "$DB_FILE" "$DB_FILE"; then
            echo "Database restored successfully from S3"
          else
            echo "WARNING: No backup available - Overseerr will start fresh"
          fi

          echo "Restore complete"
          EOF
        ]
      }

      template {
        destination = "local/litestream.yml"
        data        = <<-EOF
{{ with secret "nomad/default/overseerr" }}
dbs:
  - path: /alloc/data/db/db.sqlite3
    replicas:
      - name: overseerr
        type: s3
        bucket: overseerr-litestream
        path: db
        endpoint: http://minio-minio.virtual.consul
        access-key-id: {{ .Data.data.MINIO_ACCESS_KEY }}
        secret-access-key: {{ .Data.data.MINIO_SECRET_KEY }}
        force-path-style: true
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
{{ with secret "nomad/default/overseerr" }}
dbs:
  - path: /alloc/data/db/db.sqlite3
    replicas:
      - name: overseerr
        type: s3
        bucket: overseerr-litestream
        path: db
        endpoint: http://minio-minio.virtual.consul
        access-key-id: {{ .Data.data.MINIO_ACCESS_KEY }}
        secret-access-key: {{ .Data.data.MINIO_SECRET_KEY }}
        force-path-style: true
        sync-interval: 5m
        snapshot-interval: 1h
        retention: 168h
        retention-check-interval: 1h
{{ end }}
EOF
      }

      vault {}

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }

    task "overseerr" {
      driver = "docker"

      config {
        image = "sctx/overseerr:latest"

        volumes = [
          "../alloc/data/db:/app/config/db",
        ]
      }

      volume_mount {
        volume      = "config"
        destination = "/app/config"
      }

      env {
        TZ = "Europe/London"
      }

      resources {
        cpu        = 200
        memory     = 256
        memory_max = 512
      }
    }

    service {
      name     = "overseerr"
      provider = "consul"
      port     = "5055"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        name     = "overseerr-alive"
        type     = "http"
        path     = "/api/v1/status"
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
        "traefik.http.routers.overseerr.rule=Host(`overseerr.brmartin.co.uk`)",
        "traefik.http.routers.overseerr.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }
}
