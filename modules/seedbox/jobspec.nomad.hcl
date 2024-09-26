job "seedbox" {

  group "proxy" {

    task "proxy" {
      driver = "docker"

      config {
        image      = "docker.io/qmcgaw/gluetun:v3.39.1"
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
        image = "ghcr.io/linuxserver/qbittorrent:5.0.2"
      }

      resources {
        cpu    = 500
        memory = 128
      }

      env {
        PUID        = "991"
        PGID        = "997"
        WEBUI_PORT  = "${NOMAD_PORT_qbittorrent}"
        TZ          = "Europe/London"
        DOCKER_MODS = "ghcr.io/vuetorrent/vuetorrent-lsio-mod:latest"
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
