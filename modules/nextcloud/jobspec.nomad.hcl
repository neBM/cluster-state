job "nextcloud" {

  constraint {
    attribute = "${attr.cpu.arch}"
    value     = "amd64"
  }

  group "nextcloud" {
    update {
      progress_deadline = "30m"
      healthy_deadline  = "20m"
    }

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      name     = "nextcloud"
      provider = "consul"
      port     = "80"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        name     = "nextcloud-alive"
        type     = "http"
        path     = "/status.php"
        interval = "30s"
        timeout  = "10s"
        expose   = true
      }

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.nextcloud.rule=Host(`cloud.brmartin.co.uk`)",
        "traefik.http.routers.nextcloud.entrypoints=websecure",
        "traefik.http.middlewares.nextcloud-redirectregex.redirectRegex.permanent=true",
        "traefik.http.middlewares.nextcloud-redirectregex.redirectRegex.regex=https://(.*)/.well-known/(?:card|cal)dav",
        "traefik.http.middlewares.nextcloud-redirectregex.redirectRegex.replacement=https://$${1}/remote.php/dav",
        "traefik.http.routers.nextcloud.middlewares=nextcloud-redirectregex",
        "traefik.consulcatalog.connect=true",
      ]
    }

    # Redis sidecar for caching and file locking
    # Reduces NFS pressure by handling locks and cache in memory
    task "redis" {
      driver = "docker"

      config {
        image = "redis:7-alpine"
        args  = ["--save", ""] # Disable persistence, ephemeral cache only
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }
    }

    task "nextcloud" {
      driver = "docker"

      config {
        image = "nextcloud:32"
      }

      # Config directory - small, persists config.php
      volume_mount {
        volume      = "config"
        destination = "/var/www/html/config"
        read_only   = false
      }

      # Custom apps - user-installed apps
      volume_mount {
        volume      = "custom_apps"
        destination = "/var/www/html/custom_apps"
        read_only   = false
      }

      # User data - large volume for files
      volume_mount {
        volume      = "data"
        destination = "/var/www/html/data"
        read_only   = false
      }

      template {
        data        = <<-EOF
          POSTGRES_HOST=martinibar.lan:5433
          POSTGRES_DB=nextcloud
          POSTGRES_USER=nextcloud
          POSTGRES_PASSWORD={{ with secret "nomad/data/default/nextcloud" }}{{ .Data.data.db_password }}{{ end }}
          NEXTCLOUD_TRUSTED_DOMAINS=cloud.brmartin.co.uk
          OVERWRITEPROTOCOL=https
          TRUSTED_PROXIES=172.26.0.0/16 10.0.0.0/8
          REDIS_HOST=127.0.0.1
          EOF
        destination = "secrets/env"
        env         = true
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }
    }

    task "cron" {
      driver = "docker"

      config {
        image      = "nextcloud:32"
        entrypoint = ["/cron.sh"]
      }

      # Cron needs access to same volumes as main task
      volume_mount {
        volume      = "config"
        destination = "/var/www/html/config"
        read_only   = false
      }

      volume_mount {
        volume      = "custom_apps"
        destination = "/var/www/html/custom_apps"
        read_only   = false
      }

      volume_mount {
        volume      = "data"
        destination = "/var/www/html/data"
        read_only   = false
      }

      template {
        data        = <<-EOF
          REDIS_HOST=127.0.0.1
          EOF
        destination = "secrets/env"
        env         = true
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 512
      }

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }
    }

    # Config volume - small, for config.php and related
    volume "config" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_nextcloud_config"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    # Custom apps volume - for user-installed apps
    volume "custom_apps" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_nextcloud_custom_apps"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    # Data volume - large, for user files and appdata
    volume "data" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_nextcloud_data"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }
  }

  group "collabora" {
    update {
      progress_deadline = "15m"
      healthy_deadline  = "10m"
    }

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      name     = "collabora"
      provider = "consul"
      port     = "9980"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        name     = "collabora-alive"
        type     = "script"
        command  = "curl"
        args     = ["-sf", "http://localhost:9980/"]
        task     = "collabora"
        interval = "30s"
        timeout  = "5s"
      }

      connect {
        sidecar_service {
          proxy {
            transparent_proxy {}
            local_service_port = 9980
            config {
              protocol                 = "http"
              local_request_timeout_ms = 30000
              local_connect_timeout_ms = 5000
            }
            local_service_address = "127.0.0.1"
          }
        }
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.collabora.rule=Host(`collabora.brmartin.co.uk`)",
        "traefik.http.routers.collabora.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    task "collabora" {
      driver = "docker"

      config {
        image = "collabora/code:latest"
      }

      template {
        data        = <<-EOF
          aliasgroup1=https://cloud.brmartin.co.uk:443
          username=admin
          password={{ with secret "nomad/data/default/nextcloud" }}{{ .Data.data.collabora_password }}{{ end }}
          extra_params=--o:ssl.enable=false --o:ssl.termination=true
          EOF
        destination = "secrets/env"
        env         = true
      }

      resources {
        cpu        = 200
        memory     = 256
        memory_max = 1024
      }
    }
  }
}
