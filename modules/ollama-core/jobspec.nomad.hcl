job "ollama" {

  group "ollama" {

    network {
      mode = "bridge"
      port "api" {
        to = 11434
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 200
    }

    task "ollama" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.name}"
        value     = "Hestia"
      }

      config {
        image   = "ollama/ollama:0.13.5"
        runtime = "nvidia"

        volumes = [
          "../alloc/data/:/root/.ollama"
        ]
      }

      env {
        NVIDIA_DRIVER_CAPABILITIES = "all"
        NVIDIA_VISIBLE_DEVICES     = "all"
      }

      resources {
        cpu        = 100
        memory     = 256
        memory_max = 4096
      }
    }

    service {
      name     = "ollama-ollama"
      provider = "consul"
      port     = "11434"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        type     = "http"
        path     = "/"
        expose   = true
        interval = "10s"
        timeout  = "2s"
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

        sidecar_task {
          resources {
            memory_max = 1024
          }
        }
      }
    }
  }
}
