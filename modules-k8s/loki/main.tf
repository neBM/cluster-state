locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "logging"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# ConfigMap: loki.yaml configuration
resource "kubernetes_config_map" "loki_config" {
  metadata {
    name      = "${local.app_name}-config"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "loki.yaml" = yamlencode({
      auth_enabled = false

      server = {
        http_listen_port = 3100
        grpc_listen_port = 9095
      }

      common = {
        instance_addr = "127.0.0.1"
        ring = {
          kvstore = {
            store = "inmemory"
          }
        }
        replication_factor = 1
        path_prefix        = "/loki"
      }

      schema_config = {
        configs = [
          {
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "s3"
            schema       = "v13"
            index = {
              prefix = "loki_index_"
              period = "24h"
            }
          }
        ]
      }

      storage_config = {
        aws = {
          bucketnames      = var.minio_bucket
          endpoint         = var.minio_endpoint
          insecure         = true
          s3forcepathstyle = true
          region           = "us-east-1"
        }
        tsdb_shipper = {
          active_index_directory = "/loki/index"
          cache_location         = "/loki/index_cache"
        }
      }

      ingester = {
        wal = {
          enabled           = true
          dir               = "/loki/wal"
          flush_on_shutdown = true
        }
      }

      compactor = {
        working_directory             = "/loki/compactor"
        compaction_interval           = "10m"
        retention_enabled             = true
        retention_delete_delay        = "2h"
        retention_delete_worker_count = 150
        delete_request_store          = "s3"
      }

      limits_config = {
        retention_period = var.retention_period
      }
    })
  }
}

# Deployment: Loki monolithic
resource "kubernetes_deployment" "loki" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = local.app_name
        "app.kubernetes.io/instance" = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = local.app_name
          image = "grafana/loki:${var.image_tag}"

          args = ["-config.file=/etc/loki/loki.yaml", "-target=all"]

          port {
            name           = "http"
            container_port = 3100
            protocol       = "TCP"
          }

          port {
            name           = "grpc"
            container_port = 9095
            protocol       = "TCP"
          }

          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = var.minio_secret_name
                key  = "MINIO_ACCESS_KEY"
              }
            }
          }

          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = var.minio_secret_name
                key  = "MINIO_SECRET_KEY"
              }
            }
          }

          resources {
            requests = {
              memory = var.memory_request
              cpu    = var.cpu_request
            }
            limits = {
              memory = var.memory_limit
              cpu    = var.cpu_limit
            }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/loki/loki.yaml"
            sub_path   = "loki.yaml"
            read_only  = true
          }

          volume_mount {
            name       = "data"
            mount_path = "/loki"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.loki_config.metadata[0].name
          }
        }

        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

# Service: Loki ClusterIP
resource "kubernetes_service" "loki" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "3100"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "http"
      port        = 3100
      target_port = "http"
      protocol    = "TCP"
    }

    port {
      name        = "grpc"
      port        = 9095
      target_port = "grpc"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
