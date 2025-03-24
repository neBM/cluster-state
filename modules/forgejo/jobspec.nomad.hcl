job "forgejo" {
  group "forgejo" {

    network {
      mode = "bridge"
      port "forgejo" {
        to = 3000
      }
      port "websocket" {
        to = 2375
      }
      port "cache_server" {}
    }

    task "forgejo" {
      driver = "docker"

      config {
        image = "codeberg.org/forgejo/forgejo:10.0.3"

        ports = ["forgejo"]

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

      service {
        port     = "forgejo"
        provider = "consul"
        tags = [
          "traefik.enable=true",

          "traefik.http.routers.forgejo.entrypoints=websecure",
          "traefik.http.routers.forgejo.rule=Host(`git.brmartin.co.uk`)"
        ]
      }
    }

    task "runner" {
      driver = "docker"

      config {
        image = "data.forgejo.org/forgejo/runner:6.3.1"

        command = "sh"
        args    = ["-c", "sleep 5; forgejo-runner daemon --config=${NOMAD_TASK_DIR}/config.yml"]
      }

      volume_mount {
        volume      = "runner_data"
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
            dir: "{{ env "NOMAD_ALLOC_DIR" }}/data/cache"
            host: "127.0.0.1"
            port: {{ env "NOMAD_PORT_cache_server" }}
          container:
            network: "host"
            enable_ipv6: false
            privileged: true
            options: "-v /var/run/docker.sock:/var/run/docker.sock"
            workdir_parent:
            valid_volumes: ["/var/run/docker.sock"]
            docker_host: ""
            force_pull: false
          host:
            workdir_parent:
          EOF

        destination = "local/config.yml"
      }

      env {
        DOCKER_HOST = "tcp://127.0.0.1:2375"
      }

      service {
        port     = "cache_server"
        provider = "consul"
      }
    }

    task "docker-in-docker" {
      driver = "docker"

      config {
        image      = "docker:dind"
        privileged = true

        command = "dockerd"
        args    = ["-H=tcp://0.0.0.0:2375", "-H=unix:///var/run/docker.sock", "--tls=false", "--default-address-pool=base=10.255.0.0/24,size=29"]

        mount {
          type   = "bind"
          source = "local"
          target = "/var/lib/docker"
        }
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 4096
      }

      service {
        port     = "websocket"
        provider = "consul"
      }
    }

    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_forgejo_data"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    volume "runner_data" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_forgejo-runner_data"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    ephemeral_disk {
      migrate = true
      size    = 10000
    }
  }
}
