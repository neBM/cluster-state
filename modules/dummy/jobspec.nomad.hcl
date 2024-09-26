job "hello-world" {
  datacenters = ["dc1"]

  group "servers" {
    count = 1

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

    network {
      mode = "bridge"
      port "www" {
        to = 8001
      }
    }

    service {
      port     = "www"
      provider = "consul"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.web.rule=Host(`hello-world.brmartin.co.uk`)",
      ]
    }
  }
}
