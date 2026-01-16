job "minio" {

  group "minio" {

    network {
      mode = "bridge"
      port "http" {
        to = 80
      }
      port "s3" {
        static = 9000
        to     = 9000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      # Health check via nginx proxy to MinIO health endpoint
      check {
        name     = "minio-alive"
        type     = "http"
        path     = "/minio/health/live"
        interval = "30s"
        timeout  = "5s"
        expose   = true
      }

      check {
        name     = "minio-ready"
        type     = "http"
        path     = "/minio/health/ready"
        interval = "30s"
        timeout  = "5s"
        expose   = true
        on_update = "ignore"
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

        "traefik.http.routers.minio.rule=Host(`minio.brmartin.co.uk`)",
        "traefik.http.routers.minio.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    # Direct S3 API access - bypasses service mesh for internal bulk transfers
    # Use minio-s3.service.consul:9000 for direct access
    service {
      name     = "minio-s3"
      provider = "consul"
      port     = "s3"
    }

    task "minio" {
      driver = "docker"

      vault {
        env = false
      }

      config {
        image = "quay.io/minio/minio:latest"

        args = ["server", "/data", "--console-address", ":9001"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      template {
        data = <<-EOF
      	  {{ with secret "nomad/data/default/minio" }}
          MINIO_ROOT_USER="{{.Data.data.MINIO_ROOT_USER}}"
          MINIO_ROOT_PASSWORD="{{.Data.data.MINIO_ROOT_PASSWORD}}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      env {
        MINIO_BROWSER_REDIRECT_URL = "https://minio.brmartin.co.uk"
      }

      resources {
        cpu        = 200
        memory     = 512
        memory_max = 1024
      }
    }

    task "nginx" {
      driver = "docker"

      config {
        image = "docker.io/library/nginx:1.29.4-alpine"

        mount {
          type   = "bind"
          source = "local/nginx.conf"
          target = "/etc/nginx/nginx.conf"
        }
      }

      template {
        data = <<-EOF
          user              nginx;
          worker_processes  auto;

          error_log  stderr;
          pid        /var/run/nginx.pid;

          events {
            worker_connections  1024;
          }

          http {
            include              /etc/nginx/mime.types;
            default_type         application/octet-stream;
            access_log           off;
            proxy_buffering      off;
            sendfile             on;
            keepalive_timeout    65;
            client_max_body_size 1000M;

            server {
              listen  {{ env "NOMAD_PORT_http" }};
              server_name _;

              location / {
                proxy_set_header Host $http_host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_pass http://127.0.0.1:9000/;
                proxy_connect_timeout 300;
                proxy_send_timeout    300;
                proxy_read_timeout    300;
              }

              # Health check endpoints
              location /minio/health/ {
                proxy_pass http://127.0.0.1:9000/minio/health/;
              }
            }

            server {
              listen  {{ env "NOMAD_PORT_http" }};
              server_name minio.brmartin.co.uk;

              location / {
                proxy_set_header Host $http_host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";
                proxy_pass http://127.0.0.1:9001/;
              }
            }
          }

          EOF

        destination   = "local/nginx.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }

      resources {
        cpu        = 50
        memory     = 64
        memory_max = 128
      }

      meta = {
        "service.name" = "nginx"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_minio_data"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }
  }
}
