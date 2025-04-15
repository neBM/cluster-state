job "hello-world" {
  group "servers" {

    network {
      mode = "bridge"
      port "www" {
        to = 8001
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "web" {
      driver = "docker"

      config {
        image   = "busybox:1.37.0"
        command = "httpd"
        args    = ["-v", "-f", "-p", "${NOMAD_PORT_www}", "-h", "/local"]
        ports   = ["www"]
      }

      template {
        destination = "local/index.html"
        data        = "<h1>Hello, Ben!</h1>\n"
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    service {
      port     = 8001
      provider = "consul"

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
        "traefik.http.routers.web.rule=Host(`hello-world.brmartin.co.uk`)",
        "traefik.consulcatalog.connect=true",
      ]
    }
  }
}
