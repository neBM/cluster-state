job "jayne-martin-counselling" {

  namespace = "jaynemartincounselling-prod"

  group "webserver" {

    network {
      mode = "bridge"
      port "http" {
        to = 80
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "webserver" {
      driver = "docker"

      config {
        image = "git.brmartin.co.uk/jayne-martin-counselling/website:latest"
      }

      resources {
        cpu    = 10
        memory = 32
      }
    }

    service {
      provider = "consul"
      port     = 80

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

  group "webserver-ingress-group" {

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

        "traefik.http.routers.jmc.rule=Host(`www.jaynemartincounselling.co.uk`)",
        "traefik.http.routers.jmc.entrypoints=websecure"
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "jayne-martin-counselling-webserver"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }
}
