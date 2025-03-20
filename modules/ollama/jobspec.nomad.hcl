job "ollama" {
  group "ollama" {

    network {
      port "api" {
        static = 11434
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 5000
    }

    task "ollama" {
      driver = "docker"

      constraint {
        attribute = "${node.unique.name}"
        value     = "Hestia"
      }

      config {
        image   = "ollama/ollama:latest"
        runtime = "nvidia"
        ports   = ["api"]

        volumes = [
          "alloc/data/:/root/.ollama"
        ]
      }

      env {
        NVIDIA_DRIVER_CAPABILITIES = "all"
        NVIDIA_VISIBLE_DEVICES     = "all"
      }

      resources {
        cpu    = 100
        memory = 1024
      }
    }

    service {
      provider = "consul"
      port     = "api"
    }
  }
}
