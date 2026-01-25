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

  # Labels for ES data nodes
  es_data_labels = merge(local.common_labels, {
    app  = local.es_app_name
    role = "data"
  })

  # Labels for ES tiebreaker node
  es_tiebreaker_labels = merge(local.common_labels, {
    app  = local.es_app_name
    role = "tiebreaker"
  })

  kibana_labels = merge(local.common_labels, {
    app = local.kibana_app_name
  })

  # Elastic Agent log routing annotations
  # Routes logs to logs-kubernetes.container_logs.elk-* index
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.elk"
  }

  # Discovery seed hosts for multi-node cluster
  es_discovery_seed_hosts = join(",", [
    "${local.es_app_name}-data-headless",
    "${local.es_app_name}-tiebreaker-headless"
  ])

  # Initial master nodes - only used during initial cluster bootstrap
  # Commented out after cluster is formed to prevent issues during node restarts
  # es_initial_master_nodes = join(",", [
  #   "${local.es_app_name}-data-0",
  #   "${local.es_app_name}-data-1",
  #   "${local.es_app_name}-tiebreaker-0"
  # ])
}

# =============================================================================
# Elasticsearch Configuration
# =============================================================================

# StorageClass with Retain policy for ES data persistence
resource "kubernetes_storage_class" "local_path_retain" {
  metadata {
    name = "local-path-retain"
    labels = {
      managed-by = "terraform"
    }
  }

  storage_provisioner    = "rancher.io/local-path"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = false
}

# ConfigMap for Elasticsearch data nodes
resource "kubernetes_config_map" "elasticsearch_data" {
  metadata {
    name      = "${local.es_app_name}-data-config"
    namespace = var.namespace
    labels    = local.es_data_labels
  }

  data = {
    "elasticsearch.yml" = <<-EOF
      cluster.name: "docker-cluster"
      
      network.host: 0.0.0.0
      http.port: 9200
      transport.port: 9300
      
      path.data: /usr/share/elasticsearch/data
      
      # Memory lock disabled - requires IPC_LOCK capability in container
      # Performance impact is minimal with local NVMe storage
      bootstrap.memory_lock: false
      
      xpack:
        ml.enabled: true
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

# ConfigMap for Elasticsearch tiebreaker node
resource "kubernetes_config_map" "elasticsearch_tiebreaker" {
  metadata {
    name      = "${local.es_app_name}-tiebreaker-config"
    namespace = var.namespace
    labels    = local.es_tiebreaker_labels
  }

  data = {
    "elasticsearch.yml" = <<-EOF
      cluster.name: "docker-cluster"
      
      network.host: 0.0.0.0
      http.port: 9200
      transport.port: 9300
      
      # No path.data - tiebreaker stores no data
      
      bootstrap.memory_lock: false
      
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

# StatefulSet for Elasticsearch data nodes (2 replicas)
resource "kubernetes_stateful_set" "elasticsearch_data" {
  metadata {
    name      = "${local.es_app_name}-data"
    namespace = var.namespace
    labels    = local.es_data_labels
  }

  spec {
    service_name          = "${local.es_app_name}-data-headless"
    replicas              = 2
    pod_management_policy = "Parallel"

    selector {
      match_labels = {
        app  = local.es_app_name
        role = "data"
      }
    }

    template {
      metadata {
        labels      = local.es_data_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # Node affinity to place data nodes on specific hosts
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = var.es_data_nodes
                }
              }
            }
          }
          # Anti-affinity to spread data nodes across different hosts
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_labels = {
                  app  = local.es_app_name
                  role = "data"
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

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

          # Pod name used for node.name
          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          env {
            name  = "node.name"
            value = "$(POD_NAME)"
          }

          # Node roles: master + data roles
          env {
            name  = "node.roles"
            value = "master,data,data_content,data_hot,ingest"
          }

          # Discovery configuration
          env {
            name  = "discovery.seed_hosts"
            value = local.es_discovery_seed_hosts
          }

          # Note: cluster.initial_master_nodes removed after cluster bootstrap
          # Only needed for initial cluster formation, harmful if present during node restarts

          env {
            name  = "ES_JAVA_OPTS"
            value = var.es_data_java_opts
          }

          env {
            name  = "xpack.security.enabled"
            value = "true"
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
              cpu    = var.es_data_cpu_request
              memory = var.es_data_memory_request
            }
            limits = {
              cpu    = var.es_data_cpu_limit
              memory = var.es_data_memory_limit
            }
          }

          # Readiness probe - wait for yellow status (acceptable during startup)
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

        # Config volume from ConfigMap
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.elasticsearch_data.metadata[0].name
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

    # VolumeClaimTemplate for local-path storage
    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = kubernetes_storage_class.local_path_retain.metadata[0].name
        resources {
          requests = {
            storage = var.es_data_storage_size
          }
        }
      }
    }
  }
}

# StatefulSet for Elasticsearch tiebreaker (voting-only master)
resource "kubernetes_stateful_set" "elasticsearch_tiebreaker" {
  metadata {
    name      = "${local.es_app_name}-tiebreaker"
    namespace = var.namespace
    labels    = local.es_tiebreaker_labels
  }

  spec {
    service_name = "${local.es_app_name}-tiebreaker-headless"
    replicas     = 1

    selector {
      match_labels = {
        app  = local.es_app_name
        role = "tiebreaker"
      }
    }

    template {
      metadata {
        labels      = local.es_tiebreaker_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # Node affinity to place tiebreaker on specific host
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = [var.es_tiebreaker_node]
                }
              }
            }
          }
        }

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

          # Pod name used for node.name
          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          env {
            name  = "node.name"
            value = "$(POD_NAME)"
          }

          # Node roles: voting-only master (no data)
          env {
            name  = "node.roles"
            value = "master,voting_only"
          }

          # Discovery configuration
          env {
            name  = "discovery.seed_hosts"
            value = local.es_discovery_seed_hosts
          }

          # Note: cluster.initial_master_nodes removed after cluster bootstrap
          # Only needed for initial cluster formation, harmful if present during node restarts

          env {
            name  = "ES_JAVA_OPTS"
            value = var.es_tiebreaker_java_opts
          }

          env {
            name  = "xpack.security.enabled"
            value = "true"
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
              cpu    = var.es_tiebreaker_cpu_request
              memory = var.es_tiebreaker_memory_request
            }
            limits = {
              cpu    = var.es_tiebreaker_cpu_limit
              memory = var.es_tiebreaker_memory_limit
            }
          }

          # Readiness probe - wait for yellow status
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
            initial_delay_seconds = 60
            period_seconds        = 20
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          # Startup probe - tiebreaker is slow to start on ARM with minimal heap
          startup_probe {
            http_get {
              path   = "/_cluster/health"
              port   = 9200
              scheme = "HTTPS"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 30 # 5 minutes total for slow ARM startup
          }
        }

        # Config volume from ConfigMap
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.elasticsearch_tiebreaker.metadata[0].name
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
    # No VolumeClaimTemplate - tiebreaker has no persistent storage
  }
}

# Headless Service for data node discovery
resource "kubernetes_service" "elasticsearch_data_headless" {
  metadata {
    name      = "${local.es_app_name}-data-headless"
    namespace = var.namespace
    labels    = local.es_data_labels
  }

  spec {
    selector = {
      app  = local.es_app_name
      role = "data"
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

    cluster_ip                  = "None"
    publish_not_ready_addresses = true
  }
}

# Headless Service for tiebreaker discovery
resource "kubernetes_service" "elasticsearch_tiebreaker_headless" {
  metadata {
    name      = "${local.es_app_name}-tiebreaker-headless"
    namespace = var.namespace
    labels    = local.es_tiebreaker_labels
  }

  spec {
    selector = {
      app  = local.es_app_name
      role = "tiebreaker"
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

    cluster_ip                  = "None"
    publish_not_ready_addresses = true
  }
}

# ClusterIP Service for Elasticsearch HTTP API (targets data nodes only)
resource "kubernetes_service" "elasticsearch" {
  metadata {
    name      = local.es_app_name
    namespace = var.namespace
    labels    = local.es_labels
  }

  spec {
    selector = {
      app  = local.es_app_name
      role = "data"
    }

    port {
      port        = 9200
      target_port = 9200
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# NodePort Service for Elasticsearch - for Elastic Agent/Fleet Server connectivity (targets data nodes only)
resource "kubernetes_service" "elasticsearch_nodeport" {
  metadata {
    name      = "${local.es_app_name}-nodeport"
    namespace = var.namespace
    labels    = local.es_labels
  }

  spec {
    selector = {
      app  = local.es_app_name
      role = "data"
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
        labels      = local.kibana_labels
        annotations = local.elastic_log_annotations
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
    kubernetes_stateful_set.elasticsearch_data
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
