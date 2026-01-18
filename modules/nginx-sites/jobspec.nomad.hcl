job "nginx-sites" {

  group "nginx-sites" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      name     = "nginx-sites"
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        name     = "nginx-alive"
        type     = "http"
        path     = "/health"
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

        # martinilink.co.uk and subdomains
        "traefik.http.routers.martinilink.rule=Host(`martinilink.co.uk`) || HostRegexp(`^.+\\.martinilink\\.co\\.uk$$`)",
        "traefik.http.routers.martinilink.priority=2",
        "traefik.http.routers.martinilink.entrypoints=websecure",

        # brmartin.co.uk
        "traefik.http.routers.brmartin.rule=Host(`brmartin.co.uk`) || Host(`www.brmartin.co.uk`)",
        "traefik.http.routers.brmartin.priority=2",
        "traefik.http.routers.brmartin.entrypoints=websecure",

        "traefik.consulcatalog.connect=true",
      ]
    }

    task "nginx" {
      driver = "docker"

      config {
        image = "nginx:alpine"

        mount {
          type   = "bind"
          source = "local/nginx.conf"
          target = "/etc/nginx/nginx.conf"
        }

        mount {
          type   = "bind"
          source = "local/conf.d"
          target = "/etc/nginx/conf.d"
        }
      }

      volume_mount {
        volume      = "code"
        destination = "/code"
        read_only   = true
      }

      template {
        data = <<-EOF
          user  nginx nginx;
          worker_processes  auto;

          error_log  stderr notice;
          pid        /var/run/nginx.pid;

          events {
              worker_connections  1024;
          }

          http {
              include       /etc/nginx/mime.types;
              default_type  application/octet-stream;
              access_log    off;
              sendfile      on;
              keepalive_timeout  65;

              include /etc/nginx/conf.d/*.conf;
          }
        EOF

        destination = "local/nginx.conf"
      }

      template {
        data = <<-EOF
          upstream php {
            server 127.0.0.1:9000;
          }

          server {
            listen 80 default_server;

            root /code/martinilink.co.uk.catall;
            index index.php;

            location / {
              try_files $uri $uri/ /index.php;
            }

            location ~ \.php$ {
              fastcgi_pass php;
              fastcgi_index index.php;
              include /etc/nginx/fastcgi.conf;
            }

            location = /health {
              access_log off;
              return 200 "OK";
              add_header Content-Type text/plain;
            }
          }
        EOF

        destination   = "local/conf.d/default.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }

      template {
        data = <<-EOF
          server {
            listen 80;
            server_name brmartin.co.uk;
            return 301 https://www.$host$request_uri;
          }

          server {
            listen 80;
            server_name www.brmartin.co.uk;

            add_header Access-Control-Allow-Origin "https://www.brmartin.co.uk";
            add_header X-XSS-Protection "1; mode=block";
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
            add_header X-Frame-Options "SAMEORIGIN";

            root /code/brmartin.co.uk;
            index index.php index.html;

            location / {
              try_files $uri $uri/ /index.php;
            }

            location ~* \.php$ {
              try_files $uri =404;
              fastcgi_pass php;
              fastcgi_index index.php;
              include /etc/nginx/fastcgi.conf;
            }
          }
        EOF

        destination   = "local/conf.d/brmartin.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }

      resources {
        cpu        = 50
        memory     = 64
        memory_max = 128
      }
    }

    task "php" {
      driver = "docker"

      user = "101:101"

      config {
        image = "php:8.1-fpm-alpine"
      }

      volume_mount {
        volume      = "code"
        destination = "/code"
        read_only   = true
      }

      resources {
        cpu        = 100
        memory     = 64
        memory_max = 128
      }
    }

    volume "code" {
      type            = "csi"
      read_only       = true
      source          = "glusterfs_nginx_sites_code"
      attachment_mode = "file-system"
      access_mode     = "multi-node-reader-only"
    }
  }
}
