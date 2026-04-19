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
          bucketnames      = var.s3_bucket
          endpoint         = var.s3_endpoint
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

# StatefulSet: Loki monolithic with durable local PVC for WAL/index state.
#
# Why StatefulSet (not Deployment):
#   - volumeClaimTemplate ties the PVC lifecycle to the pod identity, so a
#     pod restart reuses the same PV — WAL and local index cache survive,
#     avoiding the corrupt-WAL-on-every-restart loop that the old emptyDir
#     setup produced.
#   - Stable pod name (loki-0) is what Grafana's reference charts use for
#     monolithic and SSD-mode Loki.
#
# Why local-path (not SeaweedFS CSI):
#   - Loki's WAL is fsync-heavy on every ingest batch. FUSE round-trips to a
#     filer + volume server add milliseconds per fsync, which under sustained
#     ingest stalls the ingester loop and reintroduces liveness timeouts.
#   - Loki's own docs explicitly recommend local SSD for the WAL path.
#   - Chunks still land in SeaweedFS S3 (storage_config.aws) — this PVC is
#     just the hot working set.
resource "kubernetes_stateful_set" "loki" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas     = 1
    service_name = kubernetes_service.loki.metadata[0].name

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = local.app_name
        "app.kubernetes.io/instance" = local.app_name
      }
    }

    # Single-writer storage: never run two pods against the same PV.
    update_strategy {
      type = "RollingUpdate"
    }

    # volumeClaimTemplate creates PVC "data-loki-0" on first schedule.
    # StorageClass is late-binding (WaitForFirstConsumer) so the PV directory
    # is created on whichever node the pod lands on — node_selector pins that
    # to hestia so subsequent restarts find the same data.
    volume_claim_template {
      metadata {
        name   = "data"
        labels = local.labels
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class_name
        resources {
          requests = {
            storage = var.storage_size
          }
        }
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Allow generous WAL flush on shutdown. flush_on_shutdown=true in the
        # ingester config means a graceful SIGTERM triggers a full chunk flush
        # to S3 before exit — bounded by this grace period. Exceeding this
        # turns SIGTERM into SIGKILL mid-flush and corrupts the WAL.
        termination_grace_period_seconds = 300

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
                name = var.s3_secret_name
                key  = "MINIO_ACCESS_KEY"
              }
            }
          }

          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = var.s3_secret_name
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

          # Startup probe gives slow-boot phases (WAL replay + ring join)
          # up to 10 minutes before kubelet escalates. Liveness only starts
          # firing after this succeeds, so steady-state liveness can stay
          # tight without premature kills during recovery.
          startup_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 60
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            period_seconds    = 30
            timeout_seconds   = 10
            failure_threshold = 3
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 3
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

        # Pin to a specific node so the local-path provisioner creates the PV
        # directory deterministically. Required because local PVs are node-bound
        # — moving the pod after first bind would orphan the data.
        node_selector = var.node_selector
      }
    }
  }
}

# Service: Loki ClusterIP (also acts as the governing service for the
# StatefulSet; single-replica doesn't need per-pod DNS so a regular ClusterIP
# suffices instead of a headless service).
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
