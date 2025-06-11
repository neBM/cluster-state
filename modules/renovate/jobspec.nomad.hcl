job "renovate" {
  type = "batch"

  periodic {
    crons            = ["0 * * * *"]
    prohibit_overlap = true
  }

  group "renovate" {
    task "renovate" {
      driver = "docker"

      config {
        image = "ghcr.io/renovatebot/renovate:40.49.11"
      }

      resources {
        cpu    = 2000
        memory = 1024
      }

      env {
        RENOVATE_PLATFORM             = "gitea"
        RENOVATE_AUTODISCOVER         = "true"
        RENOVATE_GIT_AUTHOR           = "Renovate Bot <renovate@brmartin.co.uk>"
        RENOVATE_BASE_DIR             = "${NOMAD_TASK_DIR}"
        RENOVATE_CACHE_DIR            = "${NOMAD_TASK_DIR}/../tmp"
        LOG_FORMAT                    = "json"
        RENOVATE_DEPENDENCY_DASHBOARD = "true"
      }

      template {
        data = <<-EOH
          {{ range service "forgejo-forgejo-forgejo" }}
          RENOVATE_ENDPOINT = "http://{{ .Address }}:{{ .Port }}"{{ end }}
          EOH

        destination = "local/file.env"
        env         = true
      }

      template {
        data = <<-EOH
          {{with nomadVar "nomad/jobs/renovate/renovate/renovate" }}
          RENOVATE_TOKEN = "{{.RENOVATE_TOKEN}}"
          GITHUB_COM_TOKEN = "{{.GITHUB_COM_TOKEN}}"
          {{end}}
          EOH

        destination = "secrets/file.env"
        env         = true
      }
    }
  }
}
