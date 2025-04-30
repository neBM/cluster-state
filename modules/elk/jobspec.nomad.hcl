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
      port "http" {
        static = 9200
      }
      port "transport" {
        static = 9300
      }
    }

    task "elasticsearch" {
      driver = "docker"

      config {
        image = "docker.elastic.co/elasticsearch/elasticsearch:${var.elastic_version}"

        ports = ["http", "transport"]

        volumes = [
          "/mnt/docker/elastic-${node.unique.name}/config:/usr/share/elasticsearch/config",
          "/var/lib/elasticsearch:/var/lib/elasticsearch",
        ]

        ulimit {
          memlock = "-1:-1"
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
            seed_hosts:
              - hestia.lan:9300
              - heracles.lan:9300
              - nyx.lan:9300
          path:
            data: /var/lib/elasticsearch
            repo:
              - /mnt/backups
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

      service {
        name     = "elk-node-http"
        provider = "consul"
        port     = "http"

        # check {
        #   type            = "http"
        #   protocol        = "https"
        #   tls_skip_verify = true
        #   port            = "http"
        #   path            = "/_cluster/health?local=true&wait_for_status=yellow"
        #   interval        = "5s"
        #   timeout         = "2s"
        #   header {
        #     Authorization = ["Bearer {{ with nomadVar "nomad/elk/node/elasticsearch" }}{{.healthcheck_token}}{{ end }}"]
        #   }
        # }

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

      volume_mount {
        volume      = "backups"
        destination = "/mnt/backups"
      }
    }

    volume "backups" {
      type            = "csi"
      read_only       = false
      source          = "martinibar_prod_elasticsearch_backups"
      attachment_mode = "file-system"
      access_mode     = "multi-node-multi-writer"
    }
  }

  group "kibana" {

    count = 2

    network {
      port "web" {
        to = 5601
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
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }

      template {
        data = <<-EOF
          elasticsearch:
            hosts:
              - https://hestia.lan:9200
              - https://heracles.lan:9200
              - https://nyx.lan:9200
            publicBaseUrl: https://es.brmartin.co.uk
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

        check {
          name     = "healthiness"
          type     = "tcp"
          port     = "web"
          interval = "5s"
          timeout  = "2s"
        }

        check {
          name      = "readiness"
          type      = "http"
          port      = "web"
          path      = "/api/status"
          interval  = "5s"
          timeout   = "2s"
          on_update = "ignore"
        }

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.kibana.rule=Host(`kibana.brmartin.co.uk`)",
          "traefik.http.routers.kibana.entrypoints=websecure",
        ]
      }
    }
  }
}
