job "gitlab-runner" {

  group "runner" {

    network {
      mode = "bridge"
    }

    task "gitlab-runner" {
      driver = "docker"

      config {
        image      = "gitlab/gitlab-runner:latest"
        privileged = true
        args       = ["run", "--config", "/local/config.toml"]

        # Mount Docker socket for Docker executor
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      template {
        data        = <<-EOT
concurrent = 4
check_interval = 0
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "nomad-docker-runner"
  url = "https://git.brmartin.co.uk"
{{ with secret "nomad/default/gitlab-runner" }}
  token = "{{ .Data.data.runner_token }}"
{{ end }}
  executor = "docker"
  
  [runners.docker]
    tls_verify = false
    image = "alpine:latest"
    privileged = true
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/cache", "/var/run/docker.sock:/var/run/docker.sock"]
    shm_size = 0
    network_mtu = 0
EOT
        destination = "local/config.toml"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }

    service {
      name     = "gitlab-runner"
      provider = "consul"

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
          }
        }
      }
    }
  }
}
