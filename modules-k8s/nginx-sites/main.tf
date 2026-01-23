locals {
  app_name = "nginx-sites"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }

  nginx_conf = <<-EOF
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

  default_conf = <<-EOF
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

  brmartin_conf = <<-EOF
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
}

resource "kubernetes_config_map" "nginx_config" {
  metadata {
    name      = "${local.app_name}-config"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "nginx.conf"    = local.nginx_conf
    "default.conf"  = local.default_conf
    "brmartin.conf" = local.brmartin_conf
  }
}

resource "kubernetes_deployment" "nginx_sites" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Nginx container
        container {
          name  = "nginx"
          image = "nginx:${var.nginx_image_tag}"

          port {
            container_port = 80
            name           = "http"
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/conf.d/default.conf"
            sub_path   = "default.conf"
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/conf.d/brmartin.conf"
            sub_path   = "brmartin.conf"
          }

          volume_mount {
            name       = "code"
            mount_path = "/code"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # PHP-FPM container (sidecar)
        container {
          name  = "php-fpm"
          image = "php:${var.php_image_tag}"

          port {
            container_port = 9000
            name           = "fastcgi"
          }

          volume_mount {
            name       = "code"
            mount_path = "/code"
            read_only  = true
          }

          security_context {
            run_as_user  = 101
            run_as_group = 101
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map.nginx_config.metadata[0].name
          }
        }

        volume {
          name = "code"
          host_path {
            path = "/storage/v/glusterfs_nginx_sites_code"
            type = "Directory"
          }
        }

        # Multi-arch support
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64", "arm64"]
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nginx_sites" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# Ingress for brmartin.co.uk
resource "kubernetes_ingress_v1" "brmartin" {
  metadata {
    name      = "${local.app_name}-brmartin"
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = ["brmartin.co.uk", "www.brmartin.co.uk"]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = "brmartin.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.nginx_sites.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }

    rule {
      host = "www.brmartin.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.nginx_sites.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# Ingress for martinilink.co.uk
resource "kubernetes_ingress_v1" "martinilink" {
  metadata {
    name      = "${local.app_name}-martinilink"
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = ["martinilink.co.uk"]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = "martinilink.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.nginx_sites.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
