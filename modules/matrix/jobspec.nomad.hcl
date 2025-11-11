job "matrix" {

  meta = {
    "service.type" = "matrix"
  }

  group "synapse" {

    network {
      mode = "bridge"
      port "synapse" {
        to = 8008
      }
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "8008"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      check {
        type     = "http"
        path     = "/health"
        interval = "20s"
        timeout  = "5s"
        expose   = true
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol              = "http"
              local_idle_timeout_ms = 120000
            }
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.synapse.rule=Host(`matrix.brmartin.co.uk`)",
        "traefik.http.routers.synapse.entrypoints=websecure",
        "traefik.http.routers.synapse.middlewares=synapseHeaders,synapseBuffering",
        "traefik.http.middlewares.synapseHeaders.headers.accesscontrolallowmethods=GET,POST,PUT,DELETE,OPTIONS",
        "traefik.http.middlewares.synapseHeaders.headers.accesscontrolallowheaders=Origin,X-Requested-With,Content-Type,Accept,Authorization",
        "traefik.http.middlewares.synapseHeaders.headers.accesscontrolalloworiginlist=*",
        "traefik.http.middlewares.synapseBuffering.buffering.maxRequestBodyBytes=1000000000",
        "traefik.consulcatalog.connect=true",
      ]
    }

    task "synapse" {
      driver = "docker"

      config {
        image = "ghcr.io/element-hq/synapse:v1.142.0"

        volumes = [
          "/mnt/docker/matrix/synapse:/data",
          "/mnt/docker/matrix/media_store:/media_store",
        ]
      }

      env = {
        SYNAPSE_CONFIG_PATH = "${NOMAD_TASK_DIR}/synapse-config.yaml"
        SYNAPSE_WORKER      = "synapse.app.homeserver"
      }

      template {
        data = <<-EOF
          id: whatsapp
          url: http://matrix-whatsapp-bridge.virtual.consul
        	{{with nomadVar "nomad/jobs/matrix/synapse/synapse"}}
          as_token: {{.as_token}}
          hs_token: {{.hs_token}}
          {{end}}
          sender_localpart: ctvppZV8epjY9iUtTt0nR29e92V4nIJb
          rate_limited: false
          namespaces:
              users:
                  - regex: ^@whatsappbot:brmartin\.co\.uk$
                    exclusive: true
                  - regex: ^@whatsapp_.*:brmartin\.co\.uk$
                    exclusive: true
          de.sorunome.msc2409.push_ephemeral: true
          receive_ephemeral: true
          EOF

        destination = "local/matrix-whatsapp-registration.yaml"
      }

      template {
        data = <<-EOF
          server_name: "brmartin.co.uk"
          public_baseurl: https://matrix.brmartin.co.uk/
          pid_file: /data/homeserver.pid
          worker_app: synapse.app.homeserver
          listeners:
            - bind_addresses: [127.0.0.1]
              port: {{ env "NOMAD_PORT_synapse" }}
              type: http
              x_forwarded: true
              resources:
                - names: [client, federation]
          max_upload_size: 500M
          event_cache_size: 15K
          caches:
            cache_autotuning:
              max_cache_memory_usage: {{ env "NOMAD_MEMORY_MAX_LIMIT" }}M
              target_cache_memory_usage: {{ env "NOMAD_MEMORY_LIMIT" }}M
              min_cache_ttl: 5m
          database:
            name: psycopg2
            args:
              user: synapse_user
              password: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .db_password }}{{ end }}"
              database: synapse
              host: martinibar.lan
              port: 5433
              cp_min: 5
              cp_max: 10
          log_config: "{{ env "NOMAD_TASK_DIR" }}/log_config.yaml"
          registration_shared_secret: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .registration_shared_secret }}{{ end }}"
          report_stats: true
          macaroon_secret_key: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .macaroon_secret_key }}{{ end }}"
          form_secret: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .form_secret }}{{ end }}"
          signing_key_path: "/data/brmartin.co.uk.signing.key"
          suppress_key_server_warning: true
          trusted_key_servers:
            - server_name: "matrix.org"
          app_service_config_files:
            - /local/matrix-whatsapp-registration.yaml
          turn_uris: [ "turn:turn.brmartin.co.uk?transport=udp", "turn:turn.brmartin.co.uk?transport=tcp" ]
          turn_shared_secret: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .turn_shared_secret }}{{ end }}"
          turn_user_lifetime: 86400000
          turn_allow_guests: true
          forgotten_room_retention_period: 1d
          retention:
            enabled: true
            default_policy:
              min_lifetime: 1d
              max_lifetime: 1y
            allowed_lifetime_min: 1d
            allowed_lifetime_max: 1y
          media_retention:
            local_media_lifetime: 1y
            remote_media_lifetime: 1y
          rc_message:
            per_second: 1
            burst_count: 50
          url_preview_enabled: true
          url_preview_ip_range_blacklist:
            - '127.0.0.0/8'
            - '10.0.0.0/8'
            - '172.16.0.0/12'
            - '192.168.0.0/16'
            - '100.64.0.0/10'
            - '192.0.0.0/24'
            - '169.254.0.0/16'
            - '192.88.99.0/24'
            - '198.18.0.0/15'
            - '192.0.2.0/24'
            - '198.51.100.0/24'
            - '203.0.113.0/24'
            - '224.0.0.0/4'
            - '::1/128'
            - 'fe80::/10'
            - 'fc00::/7'
            - '2001:db8::/32'
            - 'ff00::/8'
            - 'fec0::/10'
          experimental_features:
            msc3861:
              enabled: true
              issuer: https://mas.brmartin.co.uk
              client_id: 0000000000000000000SYNAPSE
              client_auth_method: client_secret_basic
              client_secret: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .mas_client_secret }}{{ end }}"
              admin_token: "{{ with nomadVar "nomad/jobs/matrix/synapse/synapse" }}{{ .mas_admin_token }}{{ end }}"
              account_management_url: "https://sso.brmartin.co.uk/settings"
              introspection_endpoint: "http://matrix-mas.virtual.consul/oauth2/introspect"
        EOF

        destination = "local/synapse-config.yaml"
      }

      template {
        data = <<-EOF
          version: 1
          formatters:
            structured:
              class: synapse.logging.TerseJsonFormatter
          handlers:
            console:
              class: logging.StreamHandler
              formatter: structured
          loggers:
            synapse.federation.transport.server.federation:
              level: WARN
            synapse.access.http.8008:
              level: WARN
            synapse.util.caches.response_cache:
              level: WARN
          root:
            level: WARN
            handlers: [console]
          disable_existing_loggers: false
          EOF

        destination = "local/log_config.yaml"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }

      meta = {
        "service.name" = "synapse"
      }
    }
  }

  group "whatsapp-bridge" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "8082"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
            }
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {}
          }
        }
      }
    }

    task "whatsapp-bridge" {
      driver = "docker"

      config {
        image = "dock.mau.dev/mautrix/whatsapp:v0.2510.0"

        volumes = [
          "/mnt/docker/matrix/whatsapp-data:/data"
        ]
      }

      resources {
        cpu        = 50
        memory     = 16
        memory_max = 64
      }

      meta = {
        "service.name" = "whatsapp"
      }
    }
  }

  group "mas" {

    network {
      mode = "bridge"
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      port     = "8081"
      provider = "consul"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
            }
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.mas.rule=Host(`mas.brmartin.co.uk`) || (Host(`matrix.brmartin.co.uk`) && PathRegexp(`^/_matrix/client/(.*)/(login|logout|refresh)`))",
        "traefik.http.routers.mas.entrypoints=websecure",
        "traefik.consulcatalog.connect=true",
      ]
    }

    task "mas" {
      driver = "docker"

      config {
        image = "ghcr.io/element-hq/matrix-authentication-service:1.6.0"

        volumes = [
          "/mnt/docker/matrix/synapse-mas/config.yaml:/config.yaml:ro"
        ]
      }

      env {
        MAS_CONFIG = "/config.yaml"
      }

      resources {
        cpu        = 100
        memory     = 32
        memory_max = 64
      }

      meta = {
        "service.name" = "mas"
      }
    }
  }

  group "nginx" {

    network {
      mode = "bridge"
      port "http" {}
      port "envoy_metrics" {
        to = 9102
      }
    }

    service {
      provider = "consul"
      port     = "http"

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
      }

      connect {
        sidecar_service {
          proxy {
            config {
              protocol              = "http"
              local_idle_timeout_ms = 120000
            }
            expose {
              path {
                path            = "/metrics"
                protocol        = "http"
                local_path_port = 9102
                listener_port   = "envoy_metrics"
              }
            }
            transparent_proxy {}
          }
        }
      }

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.matrixWellKnown.rule=PathPrefix(`/.well-known/matrix`)",
        "traefik.http.routers.matrixWellKnown.entrypoints=websecure",
        "traefik.http.routers.matrixWellKnown.middlewares=matrixWellKnown",
        "traefik.http.middlewares.matrixWellKnown.headers.accesscontrolalloworiginlist=*",
        "traefik.consulcatalog.connect=true",
      ]

    }

    task "nginx" {
      driver = "docker"

      config {
        image = "docker.io/library/nginx:1.29.3-alpine"

        volumes = [
          "/mnt/docker/matrix/nginx/html:/usr/share/nginx/html:ro",
        ]

        mount {
          type   = "bind"
          source = "local/nginx.conf"
          target = "/etc/nginx/nginx.conf"
        }
      }

      template {
        data = <<-EOF
          user              nginx;
          worker_processes  auto;

          error_log  stderr;
          pid        /var/run/nginx.pid;

          events {
            worker_connections  1024;
          }

          http {
            include            /etc/nginx/mime.types;
            default_type       application/octet-stream;
            access_log         off;
            http2              on;
            proxy_buffering    off;
            sendfile           on;
            keepalive_timeout  65;

            server {
              listen  {{ env "NOMAD_PORT_http" }};

              location / {
                return  404;
              }

              location /health {
                return        200 "OK";
                default_type  text/plain;
              }

              location /.well-known/matrix {
                root          /usr/share/nginx/html;
              }
            }
          }

          EOF

        destination   = "local/nginx.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }

      resources {
        cpu    = 50
        memory = 16
      }

      meta = {
        "service.name" = "nginx"
      }
    }
  }

  group "element" {

    network {
      port "element" {
        to = 80
      }
    }

    task "element" {
      driver = "docker"

      config {
        image = "docker.io/vectorim/element-web:v1.12.3"

        ports = ["element"]

        mount {
          type   = "bind"
          source = "local/config.json"
          target = "/app/config.json"
        }
      }

      resources {
        cpu    = 100
        memory = 16
      }

      template {
        data = <<-EOF
          {
            "default_server_config": {
              "m.homeserver": {
                "base_url": "https://matrix.brmartin.co.uk",
                "server_name": "matrix.brmartin.co.uk"
              },
              "m.identity_server": {
                "base_url": "https://vector.im"
              }
            },
            "disable_custom_urls": true,
            "disable_guests": true,
            "disable_login_language_selector": true,
            "disable_3pid_login": true,
            "brand": "Element",
            "sso_redirect_options": {
              "immediate": true
            },
            "integrations_ui_url": "https://scalar.vector.im/",
            "integrations_rest_url": "https://scalar.vector.im/api",
            "integrations_widgets_urls": [
              "https://scalar.vector.im/_matrix/integrations/v1",
              "https://scalar.vector.im/api",
              "https://scalar-staging.vector.im/_matrix/integrations/v1",
              "https://scalar-staging.vector.im/api",
              "https://scalar-staging.riot.im/scalar/api"
            ],
            "bug_report_endpoint_url": "https://element.io/bugreports/submit",
            "uisi_autorageshake_app": "element-auto-uisi",
            "default_country_code": "GB",
            "show_labs_settings": false,
            "features": {},
            "default_federate": true,
            "default_theme": "light",
            "room_directory": {
              "servers": [
                "matrix.org"
              ]
            },
            "enable_presence_by_hs_url": {
              "https://matrix.org": false,
              "https://matrix-client.matrix.org": false
            },
            "setting_defaults": {
              "breadcrumbs": true
            }
          }
          EOF

        destination = "local/config.json"
      }

      service {
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.element.rule=Host(`element.brmartin.co.uk`)",
          "traefik.http.routers.element.entrypoints=websecure",
        ]

        port         = "element"
        address_mode = "host"
        provider     = "consul"
      }

      meta = {
        "service.name" = "element"
      }
    }
  }

  group "cinny" {

    network {
      port "cinny" {
        to = 80
      }
    }

    task "cinny" {
      driver = "docker"

      config {
        image = "ghcr.io/cinnyapp/cinny:v4.10.2"

        ports = ["cinny"]

        volumes = [
          "/mnt/docker/matrix/cinny/config.json:/app/config.json:ro"
        ]
      }

      resources {
        cpu    = 50
        memory = 16
      }

      service {
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.cinny.rule=Host(`cinny.brmartin.co.uk`)",
          "traefik.http.routers.cinny.entrypoints=websecure",
        ]

        port         = "cinny"
        address_mode = "host"
        provider     = "consul"
      }

      meta = {
        "service.name" = "cinny"
      }
    }
  }
}
