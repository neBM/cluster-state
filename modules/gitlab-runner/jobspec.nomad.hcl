job "gitlab-runner" {

  # AMD64 runner - runs on Hestia
  group "runner-amd64" {
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "amd64"
    }

    network {
      mode = "bridge"
    }

    task "gitlab-runner" {
      driver = "docker"

      vault {}

      config {
        image      = "gitlab/gitlab-runner:latest"
        privileged = true
        args       = ["run", "--config", "/local/config.toml"]

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      template {
        data        = <<-EOT
concurrent = 1
check_interval = 0
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "nomad-amd64"
  url = "https://git.brmartin.co.uk"
{{ with secret "nomad/default/gitlab-runner" }}
  token = "{{ .Data.data.runner_token_amd64 }}"
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
      name     = "gitlab-runner-amd64"
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

  # ARM64 runner - runs on Heracles or Nyx
  group "runner-arm64" {
    constraint {
      attribute = "${attr.cpu.arch}"
      value     = "arm64"
    }

    network {
      mode = "bridge"
    }

    task "gitlab-runner" {
      driver = "docker"

      vault {}

      config {
        image      = "gitlab/gitlab-runner:latest"
        privileged = true
        args       = ["run", "--config", "/local/config.toml"]

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      template {
        data        = <<-EOT
concurrent = 1
check_interval = 0
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "nomad-arm64"
  url = "https://git.brmartin.co.uk"
{{ with secret "nomad/default/gitlab-runner" }}
  token = "{{ .Data.data.runner_token_arm64 }}"
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
      name     = "gitlab-runner-arm64"
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
