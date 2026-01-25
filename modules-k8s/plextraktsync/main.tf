# PlexTraktSync - Sync Plex watch history with Trakt.tv
#
# Runs every 2 hours as a CronJob
# Config stored on host at /mnt/docker/downloads/config/plextraktsync

locals {
  labels = {
    app        = "plextraktsync"
    managed-by = "terraform"
  }
}

# =============================================================================
# CronJob
# =============================================================================

resource "kubernetes_cron_job_v1" "plextraktsync" {
  metadata {
    name      = "plextraktsync"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = "0 0/2 * * *" # Every 2 hours
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = local.labels
      }

      spec {
        backoff_limit = 2

        template {
          metadata {
            labels = local.labels
          }

          spec {
            restart_policy = "OnFailure"

            # Must run on Hestia where config is stored
            node_selector = {
              "kubernetes.io/hostname" = "hestia"
            }

            container {
              name    = "plextraktsync"
              image   = "${var.image}:${var.image_tag}"
              command = ["plextraktsync", "sync"]

              volume_mount {
                name       = "config"
                mount_path = "/app/config"
              }

              resources {
                requests = {
                  cpu    = "100m"
                  memory = "64Mi"
                }
                limits = {
                  cpu    = "2000m"
                  memory = "256Mi"
                }
              }
            }

            volume {
              name = "config"
              host_path {
                path = var.config_path
                type = "Directory"
              }
            }
          }
        }
      }
    }
  }
}
