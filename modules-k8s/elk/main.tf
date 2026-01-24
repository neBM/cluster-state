locals {
  es_app_name     = "elasticsearch"
  kibana_app_name = "kibana"

  common_labels = {
    managed-by  = "terraform"
    environment = "prod"
  }

  es_labels = merge(local.common_labels, {
    app = local.es_app_name
  })

  kibana_labels = merge(local.common_labels, {
    app = local.kibana_app_name
  })
}

# =============================================================================
# Elasticsearch Configuration
# =============================================================================

# ConfigMap for Elasticsearch configuration
resource "kubernetes_config_map" "elasticsearch" {
  metadata {
    name      = "${local.es_app_name}-config"
    namespace = var.namespace
    labels    = local.es_labels
  }

  data = {
    "elasticsearch.yml" = <<-EOF
      cluster.name: "docker-cluster"
      node.name: "elk-node"
      discovery.type: single-node

      network.host: 0.0.0.0
      http.port: 9200

      path.data: /usr/share/elasticsearch/data

      bootstrap.memory_lock: true

      xpack:
        ml.enabled: false
        security:
          enabled: true
          enrollment.enabled: false
          authc:
            anonymous:
              username: anonymous_user
              roles: remote_monitoring_collector
              authz_exception: false
          transport.ssl:
            enabled: true
            verification_mode: certificate
            keystore.path: /usr/share/elasticsearch/config/certs/elastic-certificates.p12
            truststore.path: /usr/share/elasticsearch/config/certs/elastic-certificates.p12
          http.ssl:
            enabled: true
            keystore.path: /usr/share/elasticsearch/config/certs/http.p12
    EOF
  }
}

# StatefulSet for Elasticsearch (single replica)
resource "kubernetes_stateful_set" "elasticsearch" {
  metadata {
    name      = local.es_app_name
    namespace = var.namespace
    labels    = local.es_labels
  }

  spec {
    service_name = "${local.es_app_name}-headless"
    replicas     = 1

    selector {
      match_labels = {
        app = local.es_app_name
      }
    }

    template {
      metadata {
        labels = local.es_labels
      }

      spec {
        # Init container to set vm.max_map_count
        init_container {
          name    = "sysctl"
          image   = "busybox:1.36"
          command = ["sh", "-c", "sysctl -w vm.max_map_count=262144"]

          security_context {
            privileged = true
          }
        }

        container {
          name  = local.es_app_name
          image = "docker.elastic.co/elasticsearch/elasticsearch:${var.es_image_tag}"

          port {
            container_port = 9200
            name           = "http"
          }

          port {
            container_port = 9300
            name           = "transport"
          }

          env {
            name  = "discovery.type"
            value = "single-node"
          }

          env {
            name  = "ES_JAVA_OPTS"
            value = var.es_java_opts
          }

          env {
            name  = "xpack.security.enabled"
            value = "true"
          }

          env {
            name  = "bootstrap.memory_lock"
            value = "true"
          }

          # PKCS12 keystore password (default for ES-generated certs)
          env {
            name  = "ELASTIC_PASSWORD"
            value = "" # Not used for API access, certs handle auth
          }

          volume_mount {
            name       = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }

          volume_mount {
            name       = "config"
            mount_path = "/usr/share/elasticsearch/config/elasticsearch.yml"
            sub_path   = "elasticsearch.yml"
          }

          volume_mount {
            name       = "certs"
            mount_path = "/usr/share/elasticsearch/config/certs"
            read_only  = true
          }

          # Mount the keystore file for PKCS12 passwords
          volume_mount {
            name       = "keystore"
            mount_path = "/usr/share/elasticsearch/config/elasticsearch.keystore"
            sub_path   = "elasticsearch.keystore"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.es_cpu_request
              memory = var.es_memory_request
            }
            limits = {
              cpu    = var.es_cpu_limit
              memory = var.es_memory_limit
            }
          }

          # Readiness probe - wait for yellow status (acceptable for single-node)
          readiness_probe {
            http_get {
              path   = "/_cluster/health?wait_for_status=yellow&timeout=1s"
              port   = 9200
              scheme = "HTTPS"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Liveness probe - basic health check
          liveness_probe {
            http_get {
              path   = "/_cluster/health"
              port   = 9200
              scheme = "HTTPS"
            }
            initial_delay_seconds = 90
            period_seconds        = 20
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          # Startup probe - allow time for index recovery
          startup_probe {
            http_get {
              path   = "/_cluster/health"
              port   = 9200
              scheme = "HTTPS"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30 # 5 minutes total
          }
        }

        # Data volume from GlusterFS via hostPath
        volume {
          name = "data"
          host_path {
            path = var.es_data_path
            type = "Directory"
          }
        }

        # Config volume from ConfigMap
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.elasticsearch.metadata[0].name
          }
        }

        # Certs volume from Secret (created manually before deploy)
        volume {
          name = "certs"
          secret {
            secret_name = "elasticsearch-certs"
          }
        }

        # Keystore volume from Secret (contains PKCS12 passwords)
        volume {
          name = "keystore"
          secret {
            secret_name = "elasticsearch-certs"
            items {
              key  = "elasticsearch.keystore"
              path = "elasticsearch.keystore"
            }
          }
        }

        # Run as elasticsearch user (uid 1000)
        security_context {
          fs_group = 1000
        }
      }
    }
  }
}

# Headless Service for StatefulSet DNS
resource "kubernetes_service" "elasticsearch_headless" {
  metadata {
    name      = "${local.es_app_name}-headless"
    namespace = var.namespace
    labels    = local.es_labels
  }

  spec {
    selector = {
      app = local.es_app_name
    }

    port {
      port        = 9200
      target_port = 9200
      name        = "http"
    }

    port {
      port        = 9300
      target_port = 9300
      name        = "transport"
    }

    cluster_ip = "None"
  }
}

# ClusterIP Service for Elasticsearch HTTP API
resource "kubernetes_service" "elasticsearch" {
  metadata {
    name      = local.es_app_name
    namespace = var.namespace
    labels    = local.es_labels
  }

  spec {
    selector = {
      app = local.es_app_name
    }

    port {
      port        = 9200
      target_port = 9200
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# NodePort Service for Elasticsearch - for Elastic Agent/Fleet Server connectivity
resource "kubernetes_service" "elasticsearch_nodeport" {
  metadata {
    name      = "${local.es_app_name}-nodeport"
    namespace = var.namespace
    labels    = local.es_labels
  }

  spec {
    selector = {
      app = local.es_app_name
    }

    port {
      port        = 9200
      target_port = 9200
      node_port   = 30092
      name        = "http"
    }

    type = "NodePort"
  }
}

# =============================================================================
# Kibana Configuration
# =============================================================================

# ConfigMap for Kibana configuration
resource "kubernetes_config_map" "kibana" {
  metadata {
    name      = "${local.kibana_app_name}-config"
    namespace = var.namespace
    labels    = local.kibana_labels
  }

  data = {
    "kibana.yml" = <<-EOF
      server:
        host: "0.0.0.0"
        port: 5601
        publicBaseUrl: "https://${var.kibana_hostname}"
        ssl.enabled: false

      elasticsearch:
        hosts: ["https://${local.es_app_name}:9200"]
        username: "$${ELASTICSEARCH_USERNAME}"
        password: "$${ELASTICSEARCH_PASSWORD}"
        requestTimeout: 600000
        ssl:
          verificationMode: certificate
          certificateAuthorities:
            - /usr/share/kibana/config/certs/elasticsearch-ca.pem

      xpack:
        encryptedSavedObjects:
          encryptionKey: "$${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY}"
        reporting:
          encryptionKey: "$${XPACK_REPORTING_ENCRYPTIONKEY}"
        security:
          encryptionKey: "$${XPACK_SECURITY_ENCRYPTIONKEY}"
        alerting:
          rules:
            run:
              alerts:
                max: 10000
    EOF
  }
}

# Deployment for Kibana
resource "kubernetes_deployment" "kibana" {
  metadata {
    name      = local.kibana_app_name
    namespace = var.namespace
    labels    = local.kibana_labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = local.kibana_app_name
      }
    }

    template {
      metadata {
        labels = local.kibana_labels
      }

      spec {
        container {
          name  = local.kibana_app_name
          image = "docker.elastic.co/kibana/kibana:${var.kibana_image_tag}"

          port {
            container_port = 5601
            name           = "http"
          }

          # Environment variables from secrets
          env_from {
            secret_ref {
              name = "kibana-credentials"
            }
          }

          env_from {
            secret_ref {
              name = "kibana-encryption-keys"
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/usr/share/kibana/config/kibana.yml"
            sub_path   = "kibana.yml"
          }

          volume_mount {
            name       = "certs"
            mount_path = "/usr/share/kibana/config/certs"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.kibana_cpu_request
              memory = var.kibana_memory_request
            }
            limits = {
              cpu    = var.kibana_cpu_limit
              memory = var.kibana_memory_limit
            }
          }

          # Startup probe - allow time for Kibana initialization
          startup_probe {
            http_get {
              path = "/api/status"
              port = 5601
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 10
            failure_threshold     = 30 # 5 minutes total
          }

          # Readiness probe
          readiness_probe {
            http_get {
              path = "/api/status"
              port = 5601
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Liveness probe
          liveness_probe {
            http_get {
              path = "/api/status"
              port = 5601
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }
        }

        # Config volume from ConfigMap
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.kibana.metadata[0].name
          }
        }

        # Certs volume from Secret (created manually before deploy)
        volume {
          name = "certs"
          secret {
            secret_name = "kibana-certs"
          }
        }
      }
    }
  }

  depends_on = [
    kubectl_manifest.kibana_credentials_external_secret,
    kubectl_manifest.kibana_encryption_keys_external_secret,
    kubernetes_stateful_set.elasticsearch
  ]
}

# ClusterIP Service for Kibana
resource "kubernetes_service" "kibana" {
  metadata {
    name      = local.kibana_app_name
    namespace = var.namespace
    labels    = local.kibana_labels
  }

  spec {
    selector = {
      app = local.kibana_app_name
    }

    port {
      port        = 5601
      target_port = 5601
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Traefik IngressRoutes
# =============================================================================

# ServersTransport for Elasticsearch backend TLS (skip verify for self-signed certs)
resource "kubectl_manifest" "elasticsearch_serverstransport" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = "elasticsearch-transport"
      namespace = var.namespace
      labels    = local.es_labels
    }
    spec = {
      serverName         = local.es_app_name
      insecureSkipVerify = true
    }
  })
}

# IngressRoute for Elasticsearch
resource "kubectl_manifest" "elasticsearch_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = local.es_app_name
      namespace = var.namespace
      labels    = local.es_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.es_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name             = kubernetes_service.elasticsearch.metadata[0].name
              port             = 9200
              scheme           = "https"
              serversTransport = "elasticsearch-transport"
            }
          ]
        }
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  })

  depends_on = [kubectl_manifest.elasticsearch_serverstransport]
}

# IngressRoute for Kibana
resource "kubectl_manifest" "kibana_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = local.kibana_app_name
      namespace = var.namespace
      labels    = local.kibana_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.kibana_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.kibana.metadata[0].name
              port = 5601
            }
          ]
        }
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  })
}
