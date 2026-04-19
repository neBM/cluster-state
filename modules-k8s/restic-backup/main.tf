# Restic Backup - Daily backup of SeaweedFS volumes
#
# Runs daily at 3am, backs up the SeaweedFS filer root to a local restic repository
# Must run on Hestia where backup destination is mounted
# Requires RESTIC_PASSWORD from Vault

locals {
  labels = {
    app        = "restic-backup"
    managed-by = "terraform"
  }

  # Backup script embedded in ConfigMap
  backup_script = <<-EOF
#!/bin/sh
set -e

export RESTIC_REPOSITORY=/repo
export RESTIC_PASSWORD_FILE=/secrets/password

# Initialize repo if needed
if ! restic snapshots >/dev/null 2>&1; then
  echo "Initializing restic repository..."
  restic init
fi

echo "Starting backup of SeaweedFS volumes..."

restic backup /data-seaweedfs \
  --tag seaweedfs \
  --tag scheduled \
  --iexclude-file=/config/excludes.txt \
  --exclude-caches \
  --exclude-if-present .nobackup \
  --skip-if-unchanged

echo "Backup complete. Running cleanup..."

# Keep 7 daily, 4 weekly, 6 monthly snapshots
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

echo "Checking repository integrity..."
restic check

echo "Backup job finished successfully"
EOF

  # Exclusions file
  excludes = <<-EOF
# Temporary and log files
*.tmp
*.log
*.sock

# SQLite temp files
*-wal
*-shm

# Cache directories
cache
.cache

# Log directories
logs
log

# Plex/Jellyfin regenerable data
codecs
crash reports
diagnostics
updates
media
metadata
transcodes

EOF
}

# =============================================================================
# SeaweedFS filer root PV/PVC — mounts /buckets (all CSI-provisioned volumes)
# =============================================================================

resource "kubernetes_persistent_volume" "seaweedfs_filer" {
  metadata {
    name   = "restic-seaweedfs-filer-root"
    labels = local.labels
  }

  spec {
    capacity = {
      storage = "100Gi"
    }

    access_modes                     = ["ReadOnlyMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "seaweedfs"

    persistent_volume_source {
      csi {
        driver        = "seaweedfs-csi-driver"
        volume_handle = "/buckets"
        read_only     = true
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "seaweedfs_filer" {
  metadata {
    name      = "restic-seaweedfs-filer-root"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadOnlyMany"]
    storage_class_name = "seaweedfs"
    volume_name        = kubernetes_persistent_volume.seaweedfs_filer.metadata[0].name

    resources {
      requests = {
        storage = "100Gi"
      }
    }
  }
}

# =============================================================================
# ConfigMap for scripts
# =============================================================================

resource "kubernetes_config_map" "backup_scripts" {
  metadata {
    name      = "restic-backup-scripts"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "backup.sh"    = local.backup_script
    "excludes.txt" = local.excludes
  }
}

# =============================================================================
# CronJob
# =============================================================================

resource "kubernetes_cron_job_v1" "restic_backup" {
  metadata {
    name      = "restic-backup"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = "0 3 * * *" # Daily at 3am
    timezone                      = "Europe/London"
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

            # Must run on Hestia where backup destination is mounted
            node_selector = {
              "kubernetes.io/hostname" = "hestia"
            }

            container {
              name    = "restic"
              image   = "${var.image}:${var.image_tag}"
              command = ["/bin/sh", "/config/backup.sh"]

              volume_mount {
                name       = "data-seaweedfs"
                mount_path = "/data-seaweedfs"
                read_only  = true
              }

              volume_mount {
                name       = "repo"
                mount_path = "/repo"
                read_only  = false
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/config"
                read_only  = true
              }

              volume_mount {
                name       = "secrets"
                mount_path = "/secrets"
                read_only  = true
              }

              resources {
                requests = {
                  cpu    = "500m" # goldilocks: 476m
                  memory = "256Mi"
                }
                limits = {
                  cpu    = "1500m"
                  memory = "2Gi"
                }
              }
            }

            volume {
              name = "data-seaweedfs"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.seaweedfs_filer.metadata[0].name
                read_only  = true
              }
            }

            volume {
              name = "repo"
              host_path {
                path = "/mnt/csi/backups/restic"
                type = "Directory"
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.backup_scripts.metadata[0].name
                default_mode = "0755"
              }
            }

            volume {
              name = "secrets"
              secret {
                secret_name  = "restic-backup-secrets"
                default_mode = "0400"
                items {
                  key  = "RESTIC_PASSWORD"
                  path = "password"
                }
              }
            }
          }
        }
      }
    }
  }

}

# Restic backup secrets are managed outside Terraform as a plain Kubernetes Secret.
# Secret name: restic-backup-secrets
# Keys: RESTIC_PASSWORD
