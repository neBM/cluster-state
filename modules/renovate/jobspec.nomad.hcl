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
        image = "ghcr.io/renovatebot/renovate:39.90.3"
      }

      resources {
        cpu    = 2000
        memory = 512
      }

      env {
        RENOVATE_PLATFORM             = "gitea"
        RENOVATE_AUTODISCOVER         = "true"
        RENOVATE_ENDPOINT             = "https://git.brmartin.co.uk"
        RENOVATE_GIT_AUTHOR           = "Renovate Bot <renovate@brmartin.co.uk>"
        LOG_FORMAT                    = "json"
        RENOVATE_DEPENDENCY_DASHBOARD = "true"
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
