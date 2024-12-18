variable "elastic_version" {
  type = string
}

job "elk" {

  group "node" {

    count = 2

    constraint {
      distinct_hosts = true
    }

    constraint {
      attribute = "${node.unique.name}"
      operator  = "set_contains_any"
      value     = "Hestia,Nyx"
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

        mount {
          type   = "bind"
          source = "local/unicast_hosts.txt"
          target = "/usr/share/elasticsearch/config/unicast_hosts.txt"
        }
      }

      env {
        ES_PATH_CONF = "/usr/share/elasticsearch/config"
      }

      resources {
        cpu    = 2000
        memory = 2048
      }

      template {
        data = <<-EOF
          {{ range service "elk-node-elasticsearch-transport" }}
          {{ .Address }}:{{ .Port }}
          {{ end }}
          {{ range service "elk-tiebreaker-elasticsearch-transport" }}
          {{ .Address }}:{{ .Port }}
          {{ end }}
          EOF

        destination = "local/unicast_hosts.txt"
        change_mode = "noop"
      }

      service {
        name     = "elk-node-elasticsearch-http"
        provider = "consul"
        port     = "http"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.es.rule=Host(`es.brmartin.co.uk`)",
          "traefik.http.routers.es.entrypoints=websecure",
          "traefik.http.routers.es.service=es",
          "traefik.http.services.es.loadbalancer.server.scheme=https",
          "traefik.http.services.es.loadbalancer.serversTransport=es@file",
        ]
      }

      service {
        name     = "elk-node-elasticsearch-transport"
        provider = "consul"
        port     = "transport"
      }
    }
  }

  group "tiebreaker" {

    constraint {
      attribute = "${node.unique.name}"
      value     = "Neto"
    }

    network {
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

    task "elasticsearch" {
      driver = "docker"

      config {
        image = "docker.elastic.co/elasticsearch/elasticsearch:${var.elastic_version}"

        ports = ["http", "transport"]

        volumes = [
          "/mnt/docker/elastic-${node.unique.name}/config:/usr/share/elasticsearch/config",
          "/mnt/docker/elastic-${node.unique.name}/data:/usr/share/elasticsearch/data",
        ]

        ulimit {
          memlock = "-1:-1"
        }

        mount {
          type   = "bind"
          source = "local/unicast_hosts.txt"
          target = "/usr/share/elasticsearch/config/unicast_hosts.txt"
        }
      }

      env {
        ES_PATH_CONF = "/usr/share/elasticsearch/config"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }

      template {
        data = <<-EOF
          {{ range service "elk-node-elasticsearch-transport" }}
          {{ .Address }}:{{ .Port }}
          {{ end }}
          {{ range service "elk-tiebreaker-elasticsearch-transport" }}
          {{ .Address }}:{{ .Port }}
          {{ end }}
          EOF

        destination = "local/unicast_hosts.txt"
        change_mode = "noop"
      }

      service {
        name     = "elk-tiebreaker-elasticsearch-http"
        provider = "consul"
        port     = "http"
      }

      service {
        name     = "elk-tiebreaker-elasticsearch-transport"
        provider = "consul"
        port     = "transport"
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

        mount {
          type   = "bind"
          source = "local/kibana.yml"
          target = "/usr/share/kibana/config/kibana.yml"
        }
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

      template {
        data = <<-EOF
          elasticsearch:
            hosts:
              {{ range service "elk-node-elasticsearch-transport" }}
              - https://{{ .Address }}:{{ .Port }}
              {{ end }}
            username: ${ELASTICSEARCH_USERNAME}
            password: ${ELASTICSEARCH_PASSWORD}
            requestTimeout: 600000
            ssl:
              certificateAuthorities:
                - /usr/share/kibana/config/elasticsearch-ca.pem
          server:
            host: 0.0.0.0
            publicBaseUrl: https://kibana.brmartin.co.uk
            ssl:
              enabled: false
          xpack:
            encryptedSavedObjects:
              encryptionKey: ${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY}
            reporting:
              encryptionKey: ${XPACK_REPORTING_ENCRYPTIONKEY}
            security:
              encryptionKey: ${XPACK_SECURITY_ENCRYPTIONKEY}
            alerting:
              rules:
                run:
                  alerts:
                    max: 10000
          EOF

        destination = "local/kibana.yml"
        change_mode = "noop"
      }

      template {
        data = <<-EOF
          {{ with nomadVar "nomad/jobs/elk/kibana/kibana" }}
          ELASTICSEARCH_USERNAME={{.kibana_username}}
          ELASTICSEARCH_PASSWORD={{.kibana_password}}
          XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY={{.kibana_encryptedSavedObjects_encryptionKey}}
          XPACK_REPORTING_ENCRYPTIONKEY={{.kibana_reporting_encryptionKey}}
          XPACK_SECURITY_ENCRYPTIONKEY={{.kibana_security_encryptionKey}}
          {{ end }}
          {{end}}
          EOF

        destination = "secrets/file.env"
        env         = true
      }
    }
  }
}
