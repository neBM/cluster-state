locals {
  app_name = "overseerr"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "poc"
  }
}

# ConfigMap for litestream configuration
resource "kubernetes_config_map" "litestream" {
  metadata {
    name      = "${local.app_name}-litestream"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "litestream.yml" = yamlencode({
      dbs = [{
        path = "/data/db/db.sqlite3"
        replicas = [{
          name                     = "overseerr-k8s"
          type                     = "s3"
          bucket                   = var.litestream_bucket
          path                     = "db"
          endpoint                 = var.minio_endpoint
          force-path-style         = true
          sync-interval            = "5m"
          snapshot-interval        = "1h"
          retention                = "168h"
          retention-check-interval = "1h"
        }]
      }]
    })
  }
}

# PVC for overseerr config (not SQLite - that uses emptyDir with litestream)
resource "kubernetes_persistent_volume_claim" "overseerr_config" {
  metadata {
    name      = "${local.app_name}-config"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# StatefulSet with litestream sidecar
resource "kubernetes_stateful_set" "overseerr" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    service_name = local.app_name
    replicas     = 1

    selector {
      match_labels = {
        app = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Init container to restore from litestream backup
        init_container {
          name  = "litestream-restore"
          image = "litestream/litestream:${var.litestream_image_tag}"

          command = ["/bin/sh", "-c"]
          args = [<<-EOF
            set -e
            DB_DIR="/data/db"
            DB_FILE="$DB_DIR/db.sqlite3"
            mkdir -p "$DB_DIR"

            # Skip if database already exists
            if [ -f "$DB_FILE" ]; then
              echo "Database already exists, skipping restore"
              exit 0
            fi

            # Restore from S3 (MinIO)
            echo "Restoring database from S3..."
            if litestream restore -config /etc/litestream.yml -o "$DB_FILE" "$DB_FILE"; then
              echo "Database restored successfully from S3"
            else
              echo "WARNING: No backup available - Overseerr will start fresh"
            fi
          EOF
          ]

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "litestream-config"
            mount_path = "/etc/litestream.yml"
            sub_path   = "litestream.yml"
          }

          env_from {
            secret_ref {
              name = "${local.app_name}-secrets"
            }
          }

          # Litestream needs these env vars for S3 auth
          env {
            name = "LITESTREAM_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "MINIO_ACCESS_KEY"
              }
            }
          }

          env {
            name = "LITESTREAM_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "MINIO_SECRET_KEY"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        # Main overseerr container
        container {
          name  = local.app_name
          image = "sctx/overseerr:${var.image_tag}"

          port {
            container_port = 5055
            name           = "http"
          }

          # Mount config from PVC, but db from shared emptyDir
          volume_mount {
            name       = "config"
            mount_path = "/app/config"
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/config/db"
            sub_path   = "db"
          }

          env {
            name  = "TZ"
            value = "Europe/London"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/api/v1/status"
              port = 5055
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/api/v1/status"
              port = 5055
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Litestream sidecar for continuous replication
        container {
          name  = "litestream"
          image = "litestream/litestream:${var.litestream_image_tag}"

          args = ["replicate", "-config", "/etc/litestream.yml"]

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "litestream-config"
            mount_path = "/etc/litestream.yml"
            sub_path   = "litestream.yml"
          }

          env {
            name = "LITESTREAM_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "MINIO_ACCESS_KEY"
              }
            }
          }

          env {
            name = "LITESTREAM_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "MINIO_SECRET_KEY"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        # Shared emptyDir for SQLite database (ephemeral, backed by litestream)
        volume {
          name = "data"
          empty_dir {
            size_limit = "500Mi"
          }
        }

        # PVC for overseerr config files
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.overseerr_config.metadata[0].name
          }
        }

        # Litestream config from ConfigMap
        volume {
          name = "litestream-config"
          config_map {
            name = kubernetes_config_map.litestream.metadata[0].name
          }
        }

        # Prefer amd64 for better performance, but allow arm64
        affinity {
          node_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              preference {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64"]
                }
              }
            }
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64", "arm64"]
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "overseerr" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      port        = 80
      target_port = 5055
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "overseerr" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = ["overseerr-k8s.brmartin.co.uk"]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = "overseerr-k8s.brmartin.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.overseerr.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
