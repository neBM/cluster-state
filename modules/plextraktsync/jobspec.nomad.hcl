job "plextraktsync" {
  type = "batch"

  periodic {
    crons            = ["0 0/2 * * *"]
    prohibit_overlap = true
  }


  group "plextraktsync" {
    task "plextraktsync" {
      driver = "docker"

      config {
        image = "ghcr.io/taxel/plextraktsync:0.34.16"
        volumes = [
          "/mnt/docker/downloads/config/plextraktsync:/app/config"
        ]
        command = "sync"
      }

      resources {
        cpu    = 2000
        memory = 128
      }
    }
  }
}
