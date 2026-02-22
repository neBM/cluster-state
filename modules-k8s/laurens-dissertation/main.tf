# Lauren's Dissertation — TikTok Shop UK vs Amazon.co.uk profitability study
#
# Components:
# - app: FastAPI + uvicorn dashboard / scraper service (port 8000)
#
# Persistent storage:
# - data/    — SQLite database (profitability_study.db) + search_cache.json
# - archive/ — raw scraped HTML/JSON per product per day
# - logs/    — scraper log files (emptyDir; captured by Elastic Agent)
#
# On first apply the data PVC is seeded from the local data/ directory via a
# temporary busybox pod so the accumulated study data is preserved.

locals {
  labels = {
    app        = "laurens-dissertation"
    managed-by = "terraform"
  }
}

# =============================================================================
# Persistent Volume Claims
# =============================================================================

resource "kubernetes_persistent_volume_claim" "data" {
  # local-path-retain is late-binding: PVC stays Pending until a pod mounts it.
  # Don't wait for Bound status here — the deployment will trigger provisioning.
  wait_until_bound = false

  metadata {
    name      = "laurens-dissertation-data"
    namespace = var.namespace
    labels    = local.labels
    # No volume-name annotation — local-path-retain manages its own directories
  }

  spec {
    # local-path-retain: local NVMe on whichever node the pod first schedules on.
    # SQLite WAL mode requires local disk — NFS causes locking issues (see AGENTS.md).
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.data_storage_class

    resources {
      requests = {
        storage = var.data_storage_size
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "archive" {
  metadata {
    name      = "laurens-dissertation-archive"
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "volume-name" = "glusterfs_laurens_dissertation_archive"
    }
  }

  spec {
    # GlusterFS is fine for flat file storage (HTML/JSON archives, no locking)
    access_modes       = ["ReadWriteMany"]
    storage_class_name = var.archive_storage_class

    resources {
      requests = {
        storage = var.archive_storage_size
      }
    }
  }
}

# =============================================================================
# Deployment
# =============================================================================

resource "kubernetes_deployment" "app" {
  metadata {
    name      = "laurens-dissertation"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    # Must be 1: APScheduler and worker queues are single-process
    replicas = 1

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        image_pull_secrets {
          name = "gitlab-registry"
        }

        # Init container: create tables and seed the 64 brand records.
        # Idempotent — safe to run on every pod start.
        init_container {
          name  = "init-db"
          image = var.image

          command = ["/app/.venv/bin/python", "scripts/init_db.py"]

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }

        container {
          name  = "app"
          image = var.image

          port {
            container_port = 8000
            name           = "http"
          }

          # PROXY_URL — optional residential proxy for Amazon anti-bot mitigation.
          # Pod starts normally if the secret or key does not exist.
          env {
            name = "PROXY_URL"
            value_from {
              secret_key_ref {
                name     = "laurens-dissertation-secrets"
                key      = "PROXY_URL"
                optional = true
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }

          volume_mount {
            name       = "archive"
            mount_path = "/app/archive"
          }

          volume_mount {
            name       = "logs"
            mount_path = "/app/logs"
          }

          resources {
            requests = {
              # Playwright/Chromium is memory-hungry; allow headroom
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            # Allow time for workers and scheduler to initialise
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }

        volume {
          name = "archive"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.archive.metadata[0].name
          }
        }

        volume {
          name = "logs"
          empty_dir {}
        }
      }
    }
  }

}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service" "app" {
  metadata {
    name      = "laurens-dissertation"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      port        = 8000
      target_port = 8000
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Ingress — Traefik (dissertation.brmartin.co.uk)
# =============================================================================

resource "kubernetes_ingress_v1" "app" {
  metadata {
    name      = "laurens-dissertation"
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
      hosts       = [var.domain]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = var.domain
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.app.metadata[0].name
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }
}
