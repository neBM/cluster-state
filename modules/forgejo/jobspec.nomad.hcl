job "forgejo" {
  group "forgejo" {

    network {
      mode = "bridge"
      port "forgejo" {
        to = 3000
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "forgejo" {
      driver = "docker"

      config {
        image = "codeberg.org/forgejo/forgejo:10.0.0"

        volumes = [
          "/etc/timezone:/etc/timezone:ro",
          "/etc/localtime:/etc/localtime:ro"
        ]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      resources {
        cpu    = 500
        memory = 512
      }

      env {
        USER_UID = "1000"
        USER_GID = "1000"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_forgejo_data"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    service {
      port     = "3000"
      provider = "consul"

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

  group "runner" {

    network {
      mode = "bridge"
      port "cache_server" {}
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "runner" {
      driver = "docker"

      config {
        image = "data.forgejo.org/forgejo/runner:6.2.0"

        command = "forgejo-runner"
        args    = ["daemon", "--config=${NOMAD_TASK_DIR}/config.yml"]

        volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      resources {
        cpu        = 150
        memory     = 128
        memory_max = 1024
      }

      template {
        data = <<-EOF
          log:
            level: info
          runner:
            file: .runner
            capacity: 1
            timeout: 3h
            shutdown_timeout: 3h
            insecure: false
            fetch_timeout: 5s
            fetch_interval: 2s
            report_interval: 1s
            labels: []
          cache:
            enabled: true
            dir: "{{ env "NOMAD_TASK_DIR" }}/cache"
            host: "forgejo-runner.virtual.consul"
            port: {{ env "NOMAD_PORT_cache_server" }}
          container:
            network: "host"
            enable_ipv6: false
            privileged: true
            options:
            workdir_parent:
            valid_volumes: []
            docker_host: "-"
            force_pull: false
          host:
            workdir_parent:
          EOF

        destination = "local/config.yml"
      }

      env {
        DOCKER_HOST = "tcp://forgejo-docker-in-docker.virtual.consul:2375"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_forgejo-runner_data"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    service {
      port     = "cache_server"
      provider = "consul"

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

  group "docker-in-docker" {

    network {
      mode = "bridge"
      port "websocket" {
        to = 2375
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    task "docker-in-docker" {
      driver = "docker"

      config {
        image      = "docker:dind"
        privileged = true

        command = "dockerd"
        args    = ["-H=tcp://0.0.0.0:2375", "--tls=false"]
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 4096
      }
    }

    service {
      port     = "2375"
      provider = "consul"

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

  group "forgejo-ingress-group" {

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

        "traefik.http.routers.forgejo.entrypoints=websecure",
        "traefik.http.routers.forgejo.rule=Host(`git.brmartin.co.uk`)"
      ]

      connect {
        gateway {
          ingress {
            listener {
              port     = 8080
              protocol = "http"
              service {
                name  = "forgejo-forgejo"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }
}
