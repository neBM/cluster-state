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
      port "http" {
        to = 9200
      }
      port "transport" {
        to = 9300
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

        mount {
          type   = "bind"
          source = "local/elasticsearch.yml"
          target = "/usr/share/elasticsearch/config/elasticsearch.yml"
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
          cluster:
            name: "docker-cluster"
          node:
            name: {{ env "node.unique.name" }}
          network:
            host: 0.0.0.0
          http:
            publish_host: {{ env "NOMAD_HOST_IP_http" }}
            publish_port: {{ env "NOMAD_HOST_PORT_http" }}
          transport:
            publish_host: {{ env "NOMAD_HOST_IP_transport" }}
            publish_port: {{ env "NOMAD_HOST_PORT_transport" }}
          discovery:
            seed_providers: file
          xpack:
            security:
              enrollment:
                enabled: true
              transport:
                ssl:
                  enabled: true
                  verification_mode: certificate
                  client_authentication: required
                  keystore:
                    path: certs/elastic-certificates.p12
                  truststore:
                    path: certs/elastic-certificates.p12
              http:
                ssl:
                  enabled: true
                  keystore:
                    path: certs/http.p12
          bootstrap:
            memory_lock: true
          EOF

        destination = "local/elasticsearch.yml"
      }

      template {
        data = <<-EOF
          {{ range service "elk-node-transport" }}
          {{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "elk-tiebreaker-transport" }}
          {{ .Address }}:{{ .Port }}{{ end }}
          EOF

        destination = "local/unicast_hosts.txt"
        change_mode = "noop"
      }

      service {
        name     = "elk-node-http"
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
        name     = "elk-node-transport"
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
        to = 9200
      }
      port "transport" {
        to = 9300
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

        mount {
          type   = "bind"
          source = "local/elasticsearch.yml"
          target = "/usr/share/elasticsearch/config/elasticsearch.yml"
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
          cluster:
            name: "docker-cluster"
          node:
            name: {{ env "node.unique.name" }}
            roles:
              - master
          network:
            host: 0.0.0.0
          http:
            publish_host: {{ env "NOMAD_HOST_IP_http" }}
            publish_port: {{ env "NOMAD_HOST_PORT_http" }}
          transport:
            publish_host: {{ env "NOMAD_HOST_IP_transport" }}
            publish_port: {{ env "NOMAD_HOST_PORT_transport" }}
          discovery:
            seed_providers: file
          xpack:
            security:
              enrollment:
                enabled: true
              transport:
                ssl:
                  enabled: true
                  verification_mode: certificate
                  client_authentication: required
                  keystore:
                    path: certs/elastic-certificates.p12
                  truststore:
                    path: certs/elastic-certificates.p12
              http:
                ssl:
                  enabled: true
                  keystore:
                    path: certs/http.p12
          bootstrap:
            memory_lock: true
          EOF

        destination = "local/elasticsearch.yml"
      }

      template {
        data = <<-EOF
          {{ range service "elk-node-transport" }}
          {{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "elk-tiebreaker-transport" }}
          {{ .Address }}:{{ .Port }}{{ end }}
          EOF

        destination = "local/unicast_hosts.txt"
        change_mode = "noop"
      }

      service {
        name     = "elk-tiebreaker-http"
        provider = "consul"
        port     = "http"
      }

      service {
        name     = "elk-tiebreaker-transport"
        provider = "consul"
        port     = "transport"
      }
    }
  }

  group "kibana" {

    count = 2

    network {
      port "web" {
        to = 5601
      }
      port "envoy_metrics" {
        to = 9102
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

      template {
        data = <<-EOF
          elasticsearch:
            hosts:
              - https://elk-lb-nginx.service.consul:9200
            username: ${ELASTICSEARCH_USERNAME}
            password: ${ELASTICSEARCH_PASSWORD}
            requestTimeout: 600000
            ssl:
              verificationMode: certificate # TODO: Change to full once we have a cert that signs for the ips
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
          EOF

        destination = "secrets/file.env"
        env         = true
      }

      service {
        port     = "web"
        provider = "consul"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.kibana.rule=Host(`kibana.brmartin.co.uk`)",
          "traefik.http.routers.kibana.entrypoints=websecure",
        ]
      }
    }
  }

  group "lb" {
    network {
      port "web" {
        static = 9200
      }
    }

    task "nginx" {
      driver = "docker"

      config {
        image = "nginx:1.27.3-alpine"

        ports = ["web"]

        mount {
          type   = "bind"
          source = "local/nginx.conf"
          target = "/etc/nginx/nginx.conf"
        }
      }

      resources {
        cpu    = 10
        memory = 16
      }

      template {
        data = <<-EOF
          user  nobody;
          worker_processes  auto;
          pid        /var/run/nginx.pid;

          events {
              worker_connections  1024;
          }
          
          stream {
            upstream es {
              {{- range service "elk-node-http" }}
              server {{ .Address }}:{{ .Port }};{{- end }}
            }

            server {
              listen {{ env "NOMAD_PORT_web" }};
              proxy_pass es;
            }
          }
          EOF

        destination = "local/nginx.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }

      service {
        port     = "web"
        provider = "consul"
      }
    }
  }
}
