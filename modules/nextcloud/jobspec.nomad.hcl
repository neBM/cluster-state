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

    task "nextcloud" {
      driver = "docker"

      config {
        image = "nextcloud:32"
      }

      volume_mount {
        volume      = "app"
        destination = "/var/www/html"
        read_only   = false
      }

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

      volume_mount {
        volume      = "app"
        destination = "/var/www/html"
        read_only   = false
      }

      volume_mount {
        volume      = "data"
        destination = "/var/www/html/data"
        read_only   = false
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

    volume "app" {
      type            = "csi"
      read_only       = false
      source          = "glusterfs_nextcloud_app"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

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
        type     = "http"
        path     = "/"
        protocol = "https"
        tls_skip_verify = true
        interval = "30s"
        timeout  = "5s"
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
        "traefik.http.routers.collabora.rule=Host(`collabora.brmartin.co.uk`)",
        "traefik.http.routers.collabora.entrypoints=websecure",
        "traefik.http.services.collabora.loadbalancer.server.scheme=https",
        "traefik.http.serversTransports.collabora.insecureSkipVerify=true",
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
