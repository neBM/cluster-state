job "matrix" {

  meta = {
    "service.type" = "matrix"
  }

  group "synapse" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "8008"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        type     = "http"
        path     = "/health"
        interval = "20s"
        timeout  = "5s"
        expose   = true
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol              = "http"
              local_idle_timeout_ms = 120000
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

    task "synapse" {
      driver = "docker"

      config {
        image = "ghcr.io/element-hq/synapse:v1.120.2"

        ports = ["8008"]

        volumes = [
          "/mnt/docker/matrix/synapse:/data",
          "/mnt/docker/matrix/media_store:/media_store",
        ]
      }

      env = {
        SYNAPSE_WORKER = "synapse.app.homeserver"
      }

      template {
        data = <<-EOF
          id: whatsapp
          url: http://matrix-whatsapp-bridge.virtual.consul
        	{{with nomadVar "nomad/jobs/matrix/synapse/synapse"}}
          as_token="{{.as_token}}"
          hs_token="{{.hs_token}}"
          {{end}}
          sender_localpart: ctvppZV8epjY9iUtTt0nR29e92V4nIJb
          rate_limited: false
          namespaces:
              users:
                  - regex: ^@whatsappbot:brmartin\.co\.uk$
                    exclusive: true
                  - regex: ^@whatsapp_.*:brmartin\.co\.uk$
                    exclusive: true
          de.sorunome.msc2409.push_ephemeral: true
          receive_ephemeral: true
          EOF

        destination = "local/matrix-whatsapp-registration.yaml"
      }

      resources {
        cpu        = 500
        memory     = 128
        memory_max = 256
      }

      meta = {
        "service.name" = "synapse"
      }
    }
  }

  group "whatsapp-bridge" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "8082"

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

    task "whatsapp-bridge" {
      driver = "docker"

      config {
        image = "dock.mau.dev/mautrix/whatsapp:v0.11.1"

        ports = ["8082"]

        volumes = [
          "/mnt/docker/matrix/whatsapp-data:/data"
        ]
      }

      resources {
        cpu        = 50
        memory     = 16
        memory_max = 32
      }

      meta = {
        "service.name" = "whatsapp"
      }
    }
  }

  group "mas" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      port     = "8081"
      provider = "consul"

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

    task "mas" {
      driver = "docker"

      config {
        image      = "ghcr.io/matrix-org/matrix-authentication-service:main"
        force_pull = true

        ports = ["8081"]

        volumes = [
          "/mnt/docker/matrix/synapse-mas/config.yaml:/config.yaml:ro"
        ]
      }

      env {
        MAS_CONFIG = "/config.yaml"
      }

      resources {
        cpu        = 100
        memory     = 32
        memory_max = 64
      }

      meta = {
        "service.name" = "mas"
      }
    }
  }

  group "syncv3" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "8008"

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

    task "syncv3" {
      driver = "docker"

      config {
        image = "ghcr.io/matrix-org/sliding-sync:v0.99.19"

        ports = ["8008"]
      }

      env = {
        SYNCV3_SERVER = "http://synapse.service.consul"
      }
      
      template {
        data = <<-EOH
        	{{with nomadVar "nomad/jobs/matrix/syncv3/syncv3"}}
          SYNCV3_SECRET="{{.SYNCV3_SECRET}}"
          SYNCV3_DB="{{.SYNCV3_DB}}"
          {{end}}
          EOH

        destination = "secrets/file.env"
        env         = true
      }

      resources {
        cpu        = 50
        memory     = 16
        memory_max = 32
      }

      meta = {
        "service.name" = "syncv3"
      }
    }
  }

  group "nginx" {

    network {
      mode = "bridge"
      port "nginx" {
        to = 80
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

      connect {
        sidecar_service {
          proxy {
            config {
              protocol              = "http"
              local_idle_timeout_ms = 120000
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

    task "nginx" {
      driver = "docker"

      config {
        image = "docker.io/library/nginx:1.27.3-alpine"

        ports = ["80"]

        volumes = [
          "/mnt/docker/matrix/nginx/templates:/etc/nginx/templates:ro",
          "/mnt/docker/matrix/nginx/html:/usr/share/nginx/html:ro",
        ]
      }

      env = {
        NGINX_PORT = "80"
      }

      resources {
        cpu    = 50
        memory = 16
      }

      meta = {
        "service.name" = "nginx"
      }
    }
  }

  group "synapse-ingress-group" {

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

        "traefik.http.routers.synapse.rule=Host(`matrix.brmartin.co.uk`)",
        "traefik.http.routers.synapse.entrypoints=websecure",
        "traefik.http.routers.synapse.middlewares=synapseHeaders,synapseBuffering",
        "traefik.http.middlewares.synapseHeaders.headers.accesscontrolallowmethods=GET,POST,PUT,DELETE,OPTIONS",
        "traefik.http.middlewares.synapseHeaders.headers.accesscontrolallowheaders=Origin,X-Requested-With,Content-Type,Accept,Authorization",
        "traefik.http.middlewares.synapseHeaders.headers.accesscontrolalloworiginlist=*",
        "traefik.http.middlewares.synapseBuffering.buffering.maxRequestBodyBytes=1000000000",
      ]

      connect {
        gateway {
          proxy {
            config {
              local_idle_timeout_ms = 120000
            }
          }
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "matrix-synapse"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }

  group "mas-ingress-group" {

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

        "traefik.http.routers.mas.rule=Host(`mas.brmartin.co.uk`) || (Host(`matrix.brmartin.co.uk`) && PathRegexp(`^/_matrix/client/(.*)/(login|logout|refresh)`))",
        "traefik.http.routers.mas.entrypoints=websecure",
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "matrix-mas"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }

  group "wellknown-ingress-group" {

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

        "traefik.http.routers.matrixWellKnown.rule=PathPrefix(`/.well-known/matrix`)",
        "traefik.http.routers.matrixWellKnown.entrypoints=websecure",
        "traefik.http.routers.matrixWellKnown.middlewares=matrixWellKnown",
        "traefik.http.middlewares.matrixWellKnown.headers.accesscontrolalloworiginlist=*",
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "matrix-nginx"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }

  group "syncv3-ingress-group" {

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

        "traefik.http.routers.matrixsyncv3.rule=Host(`matrix.brmartin.co.uk`) && (PathPrefix(`/client`) || PathPrefix(`/_matrix/client/unstable/org.matrix.msc3575/sync`))",
        "traefik.http.routers.matrixsyncv3.entrypoints=websecure",
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "matrix-syncv3"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }

  group "element" {

    network {
      port "element" {
        to = 80
      }
    }

    task "element" {
      driver = "docker"

      config {
        image = "docker.io/vectorim/element-web:v1.11.87"

        ports = ["element"]

        volumes = [
          "/mnt/docker/matrix/element/config.json:/app/config.json:ro"
        ]
      }

      resources {
        cpu    = 100
        memory = 16
      }

      service {
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.element.rule=Host(`element.brmartin.co.uk`)",
          "traefik.http.routers.element.entrypoints=websecure",
        ]

        port         = "element"
        address_mode = "host"
        provider     = "consul"
      }

      meta = {
        "service.name" = "element"
      }
    }
  }

  group "cinny" {

    network {
      port "cinny" {
        to = 80
      }
    }

    task "cinny" {
      driver = "docker"

      config {
        image = "ghcr.io/cinnyapp/cinny:v4.2.3"

        ports = ["cinny"]

        volumes = [
          "/mnt/docker/matrix/cinny/config.json:/app/config.json:ro"
        ]
      }

      resources {
        cpu    = 50
        memory = 16
      }

      service {
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.cinny.rule=Host(`cinny.brmartin.co.uk`)",
          "traefik.http.routers.cinny.entrypoints=websecure",
        ]

        port         = "cinny"
        address_mode = "host"
        provider     = "consul"
      }

      meta = {
        "service.name" = "cinny"
      }
    }
  }
}
