job "keycloak" {

  group "keycloak" {

    network {
      mode = "bridge"
      port "http" {
        to = 8080
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "8080"

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

    task "keycloak" {
      driver = "docker"

      config {
        image = "quay.io/keycloak/keycloak:26.1.4"

        args = ["start"]
      }

      env = {
        KC_DB                = "postgres"
        KC_DB_USERNAME       = "keycloak"
        KC_DB_URL_HOST       = "martinibar.lan"
        KC_DB_URL_PORT       = "5433"
        KC_DB_URL_PROPERTIES = "?sslmode=disable"
        KC_DB_URL_DATABASE   = "keycloak"
        KC_HTTP_ENABLED      = "true"
        KC_PROXY_HEADERS     = "xforwarded"
        KC_HTTP_HOST         = "127.0.0.1"
        KC_HOSTNAME          = "sso.brmartin.co.uk"
        JAVA_OPTS_KC_HEAP    = "-Xms200m -Xmx200m"
      }

      resources {
        cpu        = 500
        memory     = 250
        memory_max = 1024
      }

      template {
        data = <<-EOF
          {{ with nomadVar "nomad/jobs/keycloak/keycloak/keycloak" }}
          KC_DB_PASSWORD={{.keycloak_db_password}}
          {{ end }}
          EOF

        destination = "secrets/file.env"
        env         = true
      }
    }

    meta = {
      "service.name" = "keycloak"
    }
  }

  group "keycloak-ingress-group" {

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

        "traefik.http.routers.keycloak.rule=Host(`sso.brmartin.co.uk`)",
        "traefik.http.routers.keycloak.entrypoints=websecure",
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "keycloak-keycloak"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }
}
