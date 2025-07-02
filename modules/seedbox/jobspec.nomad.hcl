job "seedbox" {

  group "proxy" {

    task "proxy" {
      driver = "docker"

      config {
        image      = "docker.io/qmcgaw/gluetun:v3.40.0"
        force_pull = true

        cap_add = ["NET_ADMIN"]

        sysctl = {
          "net.ipv6.conf.all.disable_ipv6" = "1"
        }
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 512
      }

      env {
        VPN_SERVICE_PROVIDER = "ipvanish"
        SERVER_COUNTRIES     = "Switzerland"
        HTTPPROXY            = "on"
      }

      template {
        data = <<-EOH
        	{{with nomadVar "nomad/jobs/seedbox/proxy/proxy" }}
          OPENVPN_USER = "{{.OPENVPN_USER}}"
          OPENVPN_PASSWORD = "{{.OPENVPN_PASSWORD}}"
          {{end}}
          EOH

        destination = "secrets/file.env"
        env         = true
      }
    }
  }

  # services:
  # qbittorrent-nox:
  #   # for debugging
  #   #cap_add:
  #     #- SYS_PTRACE
  #   environment:
  #     #- PAGID=10000
  #     #- PGID=1000
  #     #- PUID=1000
  #     - QBT_LEGAL_NOTICE=
  #     - QBT_WEBUI_PORT=8080
  #     #- TZ=UTC
  #     #- UMASK=022
  #   image: qbittorrentofficial/qbittorrent-nox:latest
  #   ports:
  #     # for bittorrent traffic
  #     - 6881:6881/tcp
  #     - 6881:6881/udp
  #     # for WebUI
  #     - 8080:8080/tcp
  #   read_only: true
  #   stop_grace_period: 30m
  #   tmpfs:
  #     - /tmp
  #   tty: true
  #   volumes:
  #     - <your_path>/config:/config
  #     - <your_path>/downloads:/downloads

  group "client" {

    network {
      port "qbittorrent" {}
    }

    service {
      port = "qbittorrent"

      provider = "consul"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }

    volume "media" {
      type            = "csi"
      source          = "media"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"

      mount_options {
        mount_flags = ["nolock"]
      }
    }

    volume "qbittorrent_config" {
      type            = "csi"
      source          = "qbittorrent_config"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"

      mount_options {
        mount_flags = ["nolock"]
      }
    }

    task "qbittorrent" {
      driver = "docker"

      config {
        image = "ghcr.io/qbittorrent/docker-qbittorrent-nox:5.1.2-1"
      }

      resources {
        cpu    = 500
        memory = 128
      }

      env {
        PUID             = "991"
        PGID             = "997"
        QBT_LEGAL_NOTICE = "confirm"
        QBT_WEBUI_PORT   = "${NOMAD_PORT_qbittorrent}"
        TZ               = "Europe/London"
      }

      volume_mount {
        volume      = "media"
        destination = "/media"
      }

      volume_mount {
        volume      = "qbittorrent_config"
        destination = "/config"
      }
    }
  }
}
