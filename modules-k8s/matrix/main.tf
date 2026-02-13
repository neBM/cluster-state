# Matrix - Federated communication platform
#
# Components:
# - synapse: Matrix homeserver (port 8008)
# - mas: Matrix Authentication Service (port 8081)
# - whatsapp-bridge: Mautrix WhatsApp bridge (port 8082)
# - nginx: Well-known endpoints (port 8080)
# - element: Element web client (port 80)
# - cinny: Cinny web client (port 80)
#
# External PostgreSQL on 192.168.1.10:5433

locals {
  synapse_labels = {
    app       = "matrix"
    component = "synapse"
  }
  mas_labels = {
    app       = "matrix"
    component = "mas"
  }
  whatsapp_labels = {
    app       = "matrix"
    component = "whatsapp-bridge"
  }
  nginx_labels = {
    app       = "matrix"
    component = "nginx"
  }
  element_labels = {
    app       = "matrix"
    component = "element"
  }
  cinny_labels = {
    app       = "matrix"
    component = "cinny"
  }

  # Elastic Agent log routing annotations
  # Routes logs to logs-kubernetes.container_logs.matrix-* index
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.matrix"
  }
}

# =============================================================================
# Synapse ConfigMaps
# =============================================================================

resource "kubernetes_config_map" "synapse_config" {
  metadata {
    name      = "synapse-config"
    namespace = var.namespace
  }

  data = {
    "homeserver.yaml" = <<-EOF
      server_name: "${var.server_name}"
      public_baseurl: https://${var.synapse_hostname}/
      pid_file: /data/homeserver.pid
      worker_app: synapse.app.homeserver
      listeners:
        - bind_addresses: ['0.0.0.0']
          port: 8008
          type: http
          x_forwarded: true
          resources:
            - names: [client, federation]
      max_upload_size: 500M
      event_cache_size: 15K
      caches:
        cache_autotuning:
          max_cache_memory_usage: 512M
          target_cache_memory_usage: 256M
          min_cache_ttl: 5m
      database:
        name: psycopg2
        args:
          user: ${var.synapse_db_user}
          password: "SYNAPSE_DB_PASSWORD_PLACEHOLDER"
          database: ${var.synapse_db_name}
          host: ${var.db_host}
          port: ${var.db_port}
          cp_min: 5
          cp_max: 10
      log_config: "/config/log_config.yaml"
      registration_shared_secret: "REGISTRATION_SHARED_SECRET_PLACEHOLDER"
      report_stats: true
      macaroon_secret_key: "MACAROON_SECRET_KEY_PLACEHOLDER"
      form_secret: "FORM_SECRET_PLACEHOLDER"
      signing_key_path: "/data/${var.server_name}.signing.key"
      suppress_key_server_warning: true
      trusted_key_servers:
        - server_name: "matrix.org"
      app_service_config_files:
        - /config/whatsapp-registration.yaml
      turn_uris: [ "turn:turn.brmartin.co.uk?transport=udp", "turn:turn.brmartin.co.uk?transport=tcp" ]
      turn_shared_secret: "TURN_SHARED_SECRET_PLACEHOLDER"
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
          issuer: https://${var.mas_hostname}
          client_id: 0000000000000000000SYNAPSE
          client_auth_method: client_secret_basic
          client_secret: "MAS_CLIENT_SECRET_PLACEHOLDER"
          admin_token: "MAS_ADMIN_TOKEN_PLACEHOLDER"
          account_management_url: "https://sso.brmartin.co.uk/settings"
          introspection_endpoint: "http://mas.${var.namespace}.svc.cluster.local:8081/oauth2/introspect"
    EOF

    "log_config.yaml" = <<-EOF
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

    "whatsapp-registration.yaml" = <<-EOF
      id: whatsapp
      url: http://whatsapp-bridge.${var.namespace}.svc.cluster.local:8082
      as_token: AS_TOKEN_PLACEHOLDER
      hs_token: HS_TOKEN_PLACEHOLDER
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
  }
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "synapse_data" {
  metadata {
    name      = "matrix-synapse-data"
    namespace = var.namespace
    annotations = {
      "volume-name" = "matrix_synapse_data"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "media_store" {
  metadata {
    name      = "matrix-media-store"
    namespace = var.namespace
    annotations = {
      "volume-name" = "matrix_media_store"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "mas_config" {
  metadata {
    name      = "matrix-config"
    namespace = var.namespace
    annotations = {
      "volume-name" = "matrix_config"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "whatsapp_data" {
  metadata {
    name      = "matrix-whatsapp-data"
    namespace = var.namespace
    annotations = {
      "volume-name" = "matrix_whatsapp_data"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

# =============================================================================
# Synapse Deployment
# =============================================================================

resource "kubernetes_deployment" "synapse" {
  metadata {
    name      = "synapse"
    namespace = var.namespace
    labels    = local.synapse_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.synapse_labels
    }

    template {
      metadata {
        labels      = local.synapse_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # PVCs provisioned via glusterfs-nfs StorageClass (NFS-backed, available on all nodes)

        init_container {
          name    = "config-processor"
          image   = "busybox:1.37"
          command = ["/bin/sh", "-c"]
          args = [<<-EOF
            # Copy config files and substitute secrets
            cp /config-template/homeserver.yaml /config/homeserver.yaml
            cp /config-template/log_config.yaml /config/log_config.yaml
            cp /config-template/whatsapp-registration.yaml /config/whatsapp-registration.yaml
            
            # Substitute placeholders with actual secrets
            sed -i "s/SYNAPSE_DB_PASSWORD_PLACEHOLDER/$DB_PASSWORD/g" /config/homeserver.yaml
            sed -i "s/REGISTRATION_SHARED_SECRET_PLACEHOLDER/$REGISTRATION_SHARED_SECRET/g" /config/homeserver.yaml
            sed -i "s/MACAROON_SECRET_KEY_PLACEHOLDER/$MACAROON_SECRET_KEY/g" /config/homeserver.yaml
            sed -i "s/FORM_SECRET_PLACEHOLDER/$FORM_SECRET/g" /config/homeserver.yaml
            sed -i "s/TURN_SHARED_SECRET_PLACEHOLDER/$TURN_SHARED_SECRET/g" /config/homeserver.yaml
            sed -i "s/MAS_CLIENT_SECRET_PLACEHOLDER/$MAS_CLIENT_SECRET/g" /config/homeserver.yaml
            sed -i "s/MAS_ADMIN_TOKEN_PLACEHOLDER/$MAS_ADMIN_TOKEN/g" /config/homeserver.yaml
            sed -i "s/AS_TOKEN_PLACEHOLDER/$AS_TOKEN/g" /config/whatsapp-registration.yaml
            sed -i "s/HS_TOKEN_PLACEHOLDER/$HS_TOKEN/g" /config/whatsapp-registration.yaml
          EOF
          ]

          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name = "REGISTRATION_SHARED_SECRET"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "registration_shared_secret"
              }
            }
          }
          env {
            name = "MACAROON_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "macaroon_secret_key"
              }
            }
          }
          env {
            name = "FORM_SECRET"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "form_secret"
              }
            }
          }
          env {
            name = "TURN_SHARED_SECRET"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "turn_shared_secret"
              }
            }
          }
          env {
            name = "MAS_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "mas_client_secret"
              }
            }
          }
          env {
            name = "MAS_ADMIN_TOKEN"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "mas_admin_token"
              }
            }
          }
          env {
            name = "AS_TOKEN"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "as_token"
              }
            }
          }
          env {
            name = "HS_TOKEN"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "hs_token"
              }
            }
          }

          volume_mount {
            name       = "config-template"
            mount_path = "/config-template"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }

        container {
          name  = "synapse"
          image = "${var.synapse_image}:${var.synapse_tag}"

          port {
            container_port = 8008
          }

          env {
            name  = "SYNAPSE_CONFIG_PATH"
            value = "/config/homeserver.yaml"
          }
          env {
            name  = "SYNAPSE_WORKER"
            value = "synapse.app.homeserver"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "media-store"
            mount_path = "/media_store"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8008
            }
            initial_delay_seconds = 30
            period_seconds        = 20
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8008
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.synapse_config.metadata[0].name
          }
        }
        volume {
          name = "config"
          empty_dir {}
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.synapse_data.metadata[0].name
          }
        }
        volume {
          name = "media-store"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.media_store.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubectl_manifest.external_secret,
    kubernetes_persistent_volume_claim.synapse_data,
    kubernetes_persistent_volume_claim.media_store,
  ]
}

resource "kubernetes_service" "synapse" {
  metadata {
    name      = "synapse"
    namespace = var.namespace
    labels    = local.synapse_labels
  }

  spec {
    selector = local.synapse_labels
    port {
      port        = 8008
      target_port = 8008
    }
  }
}

# =============================================================================
# MAS (Matrix Authentication Service) Deployment
# =============================================================================

resource "kubernetes_deployment" "mas" {
  metadata {
    name      = "mas"
    namespace = var.namespace
    labels    = local.mas_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.mas_labels
    }

    template {
      metadata {
        labels      = local.mas_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # PVCs provisioned via glusterfs-nfs StorageClass (NFS-backed, available on all nodes)

        container {
          name  = "mas"
          image = "${var.mas_image}:${var.mas_tag}"

          port {
            container_port = 8081
          }

          env {
            name  = "MAS_CONFIG"
            value = "/matrix-config/synapse-mas/config.yaml"
          }

          volume_mount {
            name       = "config"
            mount_path = "/matrix-config"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8081
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8081
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mas_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubectl_manifest.external_secret,
    kubernetes_persistent_volume_claim.mas_config,
  ]
}

resource "kubernetes_service" "mas" {
  metadata {
    name      = "mas"
    namespace = var.namespace
    labels    = local.mas_labels
  }

  spec {
    selector = local.mas_labels
    port {
      port        = 8081
      target_port = 8081
    }
  }
}

# =============================================================================
# WhatsApp Bridge Deployment
# =============================================================================

resource "kubernetes_deployment" "whatsapp_bridge" {
  metadata {
    name      = "whatsapp-bridge"
    namespace = var.namespace
    labels    = local.whatsapp_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.whatsapp_labels
    }

    template {
      metadata {
        labels      = local.whatsapp_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # PVCs provisioned via glusterfs-nfs StorageClass (NFS-backed, available on all nodes)

        container {
          name  = "whatsapp-bridge"
          image = "${var.whatsapp_image}:${var.whatsapp_tag}"

          port {
            container_port = 8082
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "16Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.whatsapp_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whatsapp_bridge" {
  metadata {
    name      = "whatsapp-bridge"
    namespace = var.namespace
    labels    = local.whatsapp_labels
  }

  spec {
    selector = local.whatsapp_labels
    port {
      port        = 8082
      target_port = 8082
    }
  }
}

# =============================================================================
# Nginx (Well-known endpoints) Deployment
# =============================================================================

resource "kubernetes_config_map" "nginx_config" {
  metadata {
    name      = "matrix-nginx-config"
    namespace = var.namespace
  }

  data = {
    "nginx.conf" = <<-EOF
      user  nginx;
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
          listen  8080;

          location / {
            return  404;
          }

          location /health {
            return        200 "OK";
            default_type  text/plain;
          }

          location /.well-known/matrix {
            root          /usr/share/nginx/html;
            add_header    Access-Control-Allow-Origin *;
          }
        }
      }
    EOF

    "server" = jsonencode({
      "m.server" = "${var.synapse_hostname}:443"
    })

    "client" = jsonencode({
      "m.homeserver" = {
        "base_url" = "https://${var.synapse_hostname}"
      }
      "org.matrix.msc3575.proxy" = {
        "url" = "https://${var.synapse_hostname}"
      }
      "org.matrix.msc2965.authentication" = {
        "issuer"  = "https://${var.mas_hostname}/"
        "account" = "https://${var.mas_hostname}/account"
      }
    })
  }
}

resource "kubernetes_deployment" "nginx" {
  metadata {
    name      = "matrix-nginx"
    namespace = var.namespace
    labels    = local.nginx_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.nginx_labels
    }

    template {
      metadata {
        labels      = local.nginx_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "nginx"
          image = "${var.nginx_image}:${var.nginx_tag}"

          port {
            container_port = 8080
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          volume_mount {
            name       = "config"
            mount_path = "/usr/share/nginx/html/.well-known/matrix/server"
            sub_path   = "server"
          }
          volume_mount {
            name       = "config"
            mount_path = "/usr/share/nginx/html/.well-known/matrix/client"
            sub_path   = "client"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.nginx_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nginx" {
  metadata {
    name      = "matrix-nginx"
    namespace = var.namespace
    labels    = local.nginx_labels
  }

  spec {
    selector = local.nginx_labels
    port {
      port        = 8080
      target_port = 8080
    }
  }
}

# =============================================================================
# Element Web Client Deployment
# =============================================================================

resource "kubernetes_config_map" "element_config" {
  metadata {
    name      = "element-config"
    namespace = var.namespace
  }

  data = {
    "config.json" = jsonencode({
      default_server_config = {
        "m.homeserver" = {
          base_url    = "https://${var.synapse_hostname}"
          server_name = var.synapse_hostname
        }
        "m.identity_server" = {
          base_url = "https://vector.im"
        }
      }
      disable_custom_urls             = true
      disable_guests                  = true
      disable_login_language_selector = true
      disable_3pid_login              = true
      brand                           = "Element"
      sso_redirect_options = {
        immediate = true
      }
      integrations_ui_url   = "https://scalar.vector.im/"
      integrations_rest_url = "https://scalar.vector.im/api"
      integrations_widgets_urls = [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
      ]
      bug_report_endpoint_url = "https://element.io/bugreports/submit"
      uisi_autorageshake_app  = "element-auto-uisi"
      default_country_code    = "GB"
      show_labs_settings      = false
      features                = {}
      default_federate        = true
      default_theme           = "light"
      room_directory = {
        servers = ["matrix.org"]
      }
      enable_presence_by_hs_url = {
        "https://matrix.org"               = false
        "https://matrix-client.matrix.org" = false
      }
      setting_defaults = {
        breadcrumbs = true
      }
    })
  }
}

resource "kubernetes_deployment" "element" {
  metadata {
    name      = "element"
    namespace = var.namespace
    labels    = local.element_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.element_labels
    }

    template {
      metadata {
        labels      = local.element_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "element"
          image = "${var.element_image}:${var.element_tag}"

          port {
            container_port = 80
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config.json"
            sub_path   = "config.json"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            tcp_socket {
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.element_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "element" {
  metadata {
    name      = "element"
    namespace = var.namespace
    labels    = local.element_labels
  }

  spec {
    selector = local.element_labels
    port {
      port        = 80
      target_port = 80
    }
  }
}

# =============================================================================
# Cinny Web Client Deployment
# =============================================================================

resource "kubernetes_config_map" "cinny_config" {
  metadata {
    name      = "cinny-config"
    namespace = var.namespace
  }

  data = {
    "config.json" = jsonencode({
      defaultHomeserver      = 0
      homeserverList         = [var.server_name]
      allowCustomHomeservers = false
      featuredCommunities = {
        openAsDefault = false
        spaces = [
          "#cinny-space:matrix.org",
          "#community:matrix.org",
          "#space:envs.net",
          "#science-space:matrix.org",
          "#libregaming-games:tchncs.de",
          "#mathematics-on:matrix.org"
        ]
        rooms = [
          "#cinny:matrix.org",
          "#freesoftware:matrix.org",
          "#pcapdroid:matrix.org",
          "#gentoo:matrix.org",
          "#PrivSec.dev:arcticfoxes.net",
          "#disroot:aria-net.org"
        ]
        servers = ["envs.net", "matrix.org", "monero.social", "mozilla.org"]
      }
      hashRouter = {
        enabled  = false
        basename = "/"
      }
    })
  }
}

resource "kubernetes_deployment" "cinny" {
  metadata {
    name      = "cinny"
    namespace = var.namespace
    labels    = local.cinny_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.cinny_labels
    }

    template {
      metadata {
        labels      = local.cinny_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "cinny"
          image = "${var.cinny_image}:${var.cinny_tag}"

          port {
            container_port = 80
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config.json"
            sub_path   = "config.json"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          liveness_probe {
            tcp_socket {
              port = 80
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            tcp_socket {
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.cinny_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "cinny" {
  metadata {
    name      = "cinny"
    namespace = var.namespace
    labels    = local.cinny_labels
  }

  spec {
    selector = local.cinny_labels
    port {
      port        = 80
      target_port = 80
    }
  }
}

# =============================================================================
# IngressRoutes
# =============================================================================

# Synapse IngressRoute (with CORS and buffering middleware)
resource "kubectl_manifest" "synapse_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "synapse"
      namespace = var.namespace
      labels    = { app = "matrix", component = "synapse" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.synapse_hostname}`)"
          kind  = "Rule"
          middlewares = [
            { name = "synapse-headers", namespace = var.namespace },
            { name = "synapse-buffering", namespace = var.namespace }
          ]
          services = [
            {
              name = kubernetes_service.synapse.metadata[0].name
              port = 8008
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# MAS IngressRoute (handles mas.brmartin.co.uk and login/logout paths on matrix.brmartin.co.uk)
resource "kubectl_manifest" "mas_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "mas"
      namespace = var.namespace
      labels    = { app = "matrix", component = "mas" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match    = "Host(`${var.mas_hostname}`) || (Host(`${var.synapse_hostname}`) && PathRegexp(`^/_matrix/client/(.*)/(login|logout|refresh)`))"
          kind     = "Rule"
          priority = 100 # Higher priority than synapse route
          services = [
            {
              name = kubernetes_service.mas.metadata[0].name
              port = 8081
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# Nginx (well-known) IngressRoute
resource "kubectl_manifest" "wellknown_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "matrix-wellknown"
      namespace = var.namespace
      labels    = { app = "matrix", component = "nginx" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match    = "PathPrefix(`/.well-known/matrix`)"
          kind     = "Rule"
          priority = 50
          middlewares = [
            { name = "wellknown-cors", namespace = var.namespace }
          ]
          services = [
            {
              name = kubernetes_service.nginx.metadata[0].name
              port = 8080
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# Element IngressRoute
resource "kubectl_manifest" "element_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "element"
      namespace = var.namespace
      labels    = { app = "matrix", component = "element" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.element_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.element.metadata[0].name
              port = 80
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# Cinny IngressRoute
resource "kubectl_manifest" "cinny_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "cinny"
      namespace = var.namespace
      labels    = { app = "matrix", component = "cinny" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.cinny_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.cinny.metadata[0].name
              port = 80
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# =============================================================================
# Middlewares
# =============================================================================

resource "kubectl_manifest" "synapse_headers" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "synapse-headers"
      namespace = var.namespace
    }
    spec = {
      headers = {
        accessControlAllowMethods    = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
        accessControlAllowHeaders    = ["Origin", "X-Requested-With", "Content-Type", "Accept", "Authorization"]
        accessControlAllowOriginList = ["*"]
      }
    }
  })
}

resource "kubectl_manifest" "synapse_buffering" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "synapse-buffering"
      namespace = var.namespace
    }
    spec = {
      buffering = {
        maxRequestBodyBytes = 1000000000
      }
    }
  })
}

resource "kubectl_manifest" "wellknown_cors" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "wellknown-cors"
      namespace = var.namespace
    }
    spec = {
      headers = {
        accessControlAllowOriginList = ["*"]
      }
    }
  })
}
