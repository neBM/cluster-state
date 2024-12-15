variable "elastic_version" {
  type = string
}

job "elk" {

  group "node" {

    count = 3

    constraint {
      distinct_hosts = true
    }

    network {
      mode = "bridge"
      port "http" {
        static = 9200
      }
      port "transport" {
        static = 9300
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "9200"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {
              exclude_inbound_ports  = ["9200", "9300"]
              exclude_outbound_ports = [9200, 9300]
            }
          }
        }
      }
    }

    service {
      provider = "consul"
      port     = "transport"
    }

    task "elasticsearch" {
      driver = "docker"

      config {
        image = "docker.elastic.co/elasticsearch/elasticsearch:${var.elastic_version}"

        ports = ["9200", "9300"]

        volumes = [
          "/mnt/docker/elastic-${node.unique.name}/config:/usr/share/elasticsearch/config",
          "/mnt/docker/elastic-${node.unique.name}/data:/usr/share/elasticsearch/data",
        ]

        ulimit {
          memlock = "-1:-1"
        }
      }

      resources {
        cpu    = 2000
        memory = 2048
      }
    }
  }

  group "kibana" {

    count = 2

    constraint {
      distinct_hosts = true
    }

    network {
      mode = "bridge"
      port "web" {
        static = 5601
      }
    }

    task "kibana" {
      driver = "docker"

      config {
        image = "docker.elastic.co/kibana/kibana:${var.elastic_version}"

        ports = ["web"]

        volumes = [
          "/mnt/docker/elastic/kibana/config:/usr/share/kibana/config",
        ]
      }

      resources {
        cpu    = 1500
        memory = 1024
      }

      service {
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.kibana.rule=Host(`kibana.brmartin.co.uk`)",
          "traefik.http.routers.kibana.entrypoints=websecure",
        ]

        port         = "web"
        address_mode = "host"
        provider     = "consul"

        check {
          type      = "http"
          path      = "/api/status"
          interval  = "10s"
          timeout   = "2s"
          on_update = "ignore"
        }
      }
    }
  }
}
