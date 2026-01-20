job "renovate" {
  type = "batch"

  periodic {
    crons            = ["0 * * * *"]
    prohibit_overlap = true
  }

  group "renovate" {
    network {
      mode = "bridge"
    }

    service {
      name = "renovate"

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
          }
        }
      }
    }

    task "renovate" {
      driver = "docker"

      config {
        image = "ghcr.io/renovatebot/renovate:42.86.0"
      }

      resources {
        cpu    = 2000
        memory = 1024
      }

      env {
        RENOVATE_PLATFORM             = "gitlab"
        RENOVATE_ENDPOINT             = "http://gitlab.virtual.consul/api/v4"
        RENOVATE_AUTODISCOVER         = "true"
        RENOVATE_GIT_AUTHOR           = "Renovate Bot <renovate@brmartin.co.uk>"
        RENOVATE_BASE_DIR             = "${NOMAD_TASK_DIR}"
        RENOVATE_CACHE_DIR            = "${NOMAD_TASK_DIR}/../tmp"
        LOG_FORMAT                    = "json"
        RENOVATE_DEPENDENCY_DASHBOARD = "true"
      }

      vault {}

      template {
        data = <<-EOH
          {{ with secret "nomad/data/default/renovate" }}
          RENOVATE_TOKEN = "{{ .Data.data.RENOVATE_TOKEN }}"
          GITHUB_COM_TOKEN = "{{ .Data.data.GITHUB_COM_TOKEN }}"
          {{ end }}
          EOH

        destination = "secrets/file.env"
        env         = true
      }
    }
  }
}
