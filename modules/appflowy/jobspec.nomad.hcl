job "appflowy" {

  group "gotrue" {

    network {
      mode = "bridge"
      port "http" {
        to = 9999
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "gotrue" {
      driver = "docker"

      vault {
        env = false
      }

      config {
        image = "appflowyinc/gotrue:latest"
      }

      env {
        GOTRUE_SITE_URL                       = "appflowy-flutter://"
        GOTRUE_JWT_EXP                        = "604800"
        GOTRUE_DB_DRIVER                      = "postgres"
        GOTRUE_URI_ALLOW_LIST                 = "https://docs.brmartin.co.uk"
        GOTRUE_EXTERNAL_KEYCLOAK_ENABLED      = "true"
        GOTRUE_EXTERNAL_KEYCLOAK_CLIENT_ID    = "appflowy"
        GOTRUE_EXTERNAL_KEYCLOAK_REDIRECT_URI = "https://docs.brmartin.co.uk/gotrue/callback"
        GOTRUE_EXTERNAL_KEYCLOAK_URL          = "https://sso.brmartin.co.uk/realms/prod"
        GOTRUE_MAILER_AUTOCONFIRM             = "true"
        GOTRUE_SMTP_HOST                      = "mail.brmartin.co.uk"
        GOTRUE_SMTP_PORT                      = "465"
        GOTRUE_MAILER_URLPATHS_CONFIRMATION   = "/gotrue/verify"
        GOTRUE_MAILER_URLPATHS_INVITE         = "/gotrue/verify"
        GOTRUE_MAILER_URLPATHS_RECOVERY       = "/gotrue/verify"
        GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE   = "/gotrue/verify"
        API_EXTERNAL_URL                      = "https://docs.brmartin.co.uk/gotrue"
        PORT                                  = "9999"
      }

      template {
        data = <<-EOF
      	  {{ with secret "nomad/data/default/appflowy" }}
          GOTRUE_JWT_SECRET = "{{.Data.data.GOTRUE_JWT_SECRET}}"
          DATABASE_URL = "postgres://appflowy:{{.Data.data.PGPASSWORD}}@appflowy-postgres.virtual.consul/appflowy?search_path=auth"
          GOTRUE_EXTERNAL_KEYCLOAK_SECRET="{{.Data.data.OIDC_CLIENT_SECRET}}"
          GOTRUE_SMTP_USER = "{{.Data.data.SMTP_USERNAME}}"
          GOTRUE_SMTP_PASS = "{{.Data.data.SMTP_PASSWORD}}"
          GOTRUE_SMTP_ADMIN_EMAIL = "{{.Data.data.SMTP_ADMIN_ADDRESS}}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu        = 100
        memory     = 1024
        memory_max = 2048
      }
    }

    service {
      provider = "consul"
      port     = "9999"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
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

        "traefik.http.routers.gotrue.rule=Host(`docs.brmartin.co.uk`) && PathPrefix(`/gotrue`)",
        "traefik.http.routers.gotrue.entrypoints=websecure",
        "traefik.http.routers.gotrue.middlewares=gotrue-csr,gotrue-stripPrefix",
        "traefik.http.middlewares.gotrue-csr.headers.accessControlAllowOriginList=https://docs.brmartin.co.uk",
        "traefik.http.middlewares.gotrue-csr.headers.accesscontrolallowheaders=*",
        "traefik.http.middlewares.gotrue-stripPrefix.stripPrefix.prefixes=/gotrue",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }

  group "cloud" {

    network {
      mode = "bridge"
      port "http" {
        to = 8000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "cloud" {
      driver = "docker"

      vault {
        env = false
      }

      config {
        image = "appflowyinc/appflowy_cloud:latest"
      }

      env {
        RUST_LOG                          = "info"
        APPFLOWY_ENVIRONMENT              = "production"
        APPFLOWY_REDIS_URI                = "redis://appflowy-redis.virtual.consul:6379"
        APPFLOWY_GOTRUE_BASE_URL          = "http://appflowy-gotrue.virtual.consul"
        APPFLOWY_S3_CREATE_BUCKET         = "false"
        APPFLOWY_S3_USE_MINIO             = "true"
        APPFLOWY_S3_MINIO_URL             = "http://minio-minio.virtual.consul"
        APPFLOWY_S3_ACCESS_KEY            = "appflowy"
        APPFLOWY_S3_BUCKET                = "appflowy"
        APPFLOWY_ACCESS_CONTROL           = "true"
        APPFLOWY_DATABASE_MAX_CONNECTIONS = "40"
        APPFLOWY_WEB_URL                  = "https://docs.brmartin.co.uk"
        APPFLOWY_BASE_URL                 = "https://docs.brmartin.co.uk"
        APPFLOWY_MAILER_SMTP_HOST         = "mail.brmartin.co.uk"
        APPFLOWY_MAILER_SMTP_PORT         = "465"
      }

      template {
        data = <<-EOF
      	  {{ with secret "nomad/data/default/appflowy" }}
          APPFLOWY_DATABASE_URL = "postgres://appflowy:{{.Data.data.PGPASSWORD}}@appflowy-postgres.virtual.consul/appflowy"
          APPFLOWY_GOTRUE_JWT_SECRET = "{{.Data.data.GOTRUE_JWT_SECRET}}"
          APPFLOWY_S3_SECRET_KEY = "{{.Data.data.S3_SECRET_KEY}}"
          APPFLOWY_MAILER_SMTP_USERNAME = "{{.Data.data.SMTP_USERNAME}}"
          APPFLOWY_MAILER_SMTP_PASSWORD = "{{.Data.data.SMTP_PASSWORD}}"
          APPFLOWY_MAILER_SMTP_EMAIL = "{{.Data.data.SMTP_FROM_ADDRESS}}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    service {
      provider = "consul"
      port     = "8000"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
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

        "traefik.http.routers.appflowy-cloud.rule=Host(`docs.brmartin.co.uk`) && (PathPrefix(`/api`) || PathPrefix(`/ws`))",
        "traefik.http.routers.appflowy-cloud.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }

  group "admin-frontend" {

    network {
      mode = "bridge"
      port "http" {
        to = 8000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "admin_frontend" {
      driver = "docker"

      config {
        image = "appflowyinc/appflowy_web:latest"
      }

      env {
        APPFLOWY_BASE_URL        = "https://docs.brmartin.co.uk"
        APPFLOWY_GOTRUE_BASE_URL = "http://appflowy-gotrue.virtual.consul"
        APPFLOWY_WS_BASE_URL     = "wss://docs.brmartin.co.uk/ws/v2"
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    service {
      provider = "consul"
      port     = "8000"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
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
    }
  }

  group "worker" {

    network {
      mode = "bridge"
      port "http" {
        to = 8000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "worker" {
      driver = "docker"

      vault {
        env = false
      }

      config {
        image = "appflowyinc/appflowy_worker:latest"
      }

      env {
        RUST_LOG                             = "info"
        APPFLOWY_ENVIRONMENT                 = "production"
        APPFLOWY_WORKER_REDIS_URL            = "redis://appflowy-redis.virtual.consul:6379"
        APPFLOWY_WORKER_ENVIRONMENT          = "production"
        APPFLOWY_WORKER_DATABASE_NAME        = "appflowy"
        APPFLOWY_WORKER_IMPORT_TICK_INTERVAL = "30"
        APPFLOWY_S3_USE_MINIO                = "true"
        APPFLOWY_S3_MINIO_URL                = "http://minio-minio.virtual.consul"
        APPFLOWY_S3_ACCESS_KEY               = "appflowy"
        APPFLOWY_S3_BUCKET                   = "appflowy"
      }

      template {
        data = <<-EOF
      	  {{ with secret "nomad/data/default/appflowy" }}
          APPFLOWY_WORKER_DATABASE_URL = "postgres://appflowy:{{.Data.data.PGPASSWORD}}@appflowy-postgres.virtual.consul/appflowy"
          APPFLOWY_S3_SECRET_KEY = "{{.Data.data.S3_SECRET_KEY}}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    service {
      provider = "consul"
      port     = "8000"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
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
    }
  }

  group "web" {

    network {
      mode = "bridge"
      port "http" {
        to = 80
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "web" {
      driver = "docker"

      config {
        image = "appflowyinc/appflowy_web:latest"
      }

      env {
        APPFLOWY_BASE_URL        = "https://docs.brmartin.co.uk"
        APPFLOWY_GOTRUE_BASE_URL = "https://docs.brmartin.co.uk/gotrue"
        APPFLOWY_WS_BASE_URL     = "wss://docs.brmartin.co.uk/ws/v2"
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    service {
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
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

        "traefik.http.routers.appflowy-web.rule=Host(`docs.brmartin.co.uk`)",
        "traefik.http.routers.appflowy-web.entrypoints=websecure",
        "traefik.http.routers.appflowy-web.middlewares=appflowy-web",
        "traefik.http.middlewares.appflowy-web.headers.contentSecurityPolicy=script-src * 'self' 'unsafe-eval' 'unsafe-inline'",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }

  group "postgres" {

    network {
      mode = "bridge"
      port "pg" {
        to = 5432
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "postgres" {
      driver = "docker"

      vault {
        env = false
      }

      config {
        image = "docker.io/pgvector/pgvector:pg16"
      }

      volume_mount {
        volume      = "postgres_data"
        destination = "/var/lib/postgresql/data"
      }

      env {
        POSTGRES_USER = "appflowy"
        POSTGRES_DB   = "appflowy"
      }

      template {
        data = <<-EOF
      	  {{ with secret "nomad/data/default/appflowy" }}
          POSTGRES_PASSWORD="{{.Data.data.PGPASSWORD}}"
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    service {
      provider = "consul"
      port     = "5432"

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
  }

  group "redis" {

    network {
      mode = "bridge"
      port "redis" {
        to = 6379
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "redis" {
      driver = "docker"

      config {
        image = "docker.io/library/redis:latest"
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }

    service {
      provider = "consul"
      port     = "6379"

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

    volume "postgres_data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_appflowy_data"
      attachment_mode = "file-system"
      access_mode     = "multi-node-single-writer"
    }
  }
}
