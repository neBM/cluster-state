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
        to = 9200
      }
      port "transport" {
        to = 9300
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    ephemeral_disk {
      migrate = true
      size    = 10000
    }

    task "elasticsearch" {
      driver = "docker"

      config {
        image = "docker.elastic.co/elasticsearch/elasticsearch:${var.elastic_version}"

        ports = ["http", "transport"]

        volumes = [
          "/mnt/docker/elastic-${node.unique.name}/config:/usr/share/elasticsearch/config",
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
        cpu        = 2000
        memory     = 2048
        memory_max = 3072
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
          path:
            data: {{ env "NOMAD_TASK_DIR" }}/data
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

      template {
        data = <<-EOF
          {{ range service "elk-node-transport|any" }}
          {{ .Address }}:{{ .Port }}{{ end }}
          EOF

        destination = "local/unicast_hosts.txt"
        change_mode = "noop"
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
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }

      template {
        data = <<-EOF
          elasticsearch:
            hosts:
              {{ range service "elk-node-http|any" }}
              - https://{{ .Address }}:{{ .Port }}{{ end }}
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
          type     = "http"
          port     = "web"
          path     = "/api/status"
          interval = "5s"
          timeout  = "2s"
        }

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
        image = "nginx:1.27.4-alpine"

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
        # change_mode = "script"
        # change_script {
        #   command = "/usr/sbin/nginx"
        #   args    = ["-s", "reload"]
        # }
      }

      service {
        port     = "web"
        provider = "consul"
      }
    }
  }
}
