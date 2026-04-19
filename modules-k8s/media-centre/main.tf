# Media Centre - Plex, Tautulli
#
# Components:
# - Plex: Media server with NVIDIA GPU transcoding, periodic sqlite backup
# - Tautulli: Plex monitoring/statistics
#
# Requirements:
# - NVIDIA GPU on Hestia node (for Plex transcoding)
# - NFS access to Synology NAS (192.168.1.10) for media files
# - SeaweedFS S3 for database backups

locals {
  plex_labels = {
    app        = "media-centre"
    component  = "plex"
    managed-by = "terraform"
  }
  tautulli_labels = {
    app        = "media-centre"
    component  = "tautulli"
    managed-by = "terraform"
  }

  # Elastic Agent log routing annotations
  # Routes logs to logs-kubernetes.container_logs.media-* index
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.media"
  }

  # Backup configuration
  plex_backup_bucket   = "plex-backup"
  plex_backup_endpoint = "http://seaweedfs-s3.default.svc.cluster.local:8333"
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "plex_config" {
  metadata {
    name      = "plex-config"
    namespace = var.namespace
  }
  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# Plex SQLite databases — node-local on hestia.
# Previously provisioned via the Plex StatefulSet's volumeClaimTemplate
# (plex-data-plex-0). Now a standalone PVC so the workload can be a
# Deployment. WaitForFirstConsumer on the local-path provisioner binds the
# PV to whichever node the first consumer (the plex pod, pinned to hestia
# via nodeSelector) schedules onto.
resource "kubernetes_persistent_volume_claim" "plex_data" {
  metadata {
    name      = "plex-data"
    namespace = var.namespace
  }
  spec {
    storage_class_name = "local-path"
    access_modes       = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
}

# =============================================================================
# Synology NAS NFS PersistentVolumes (soft mount)
#
# Inline nfs{} volumes in pod specs use kernel-default 'hard' mounts.
# A hard mount blocks kernel NFS threads indefinitely when the NAS is
# unreachable, which starves the node network stack and causes crashes.
#
# PVs with mount_options = ["soft"] cause the kernel to return EIO to the
# application after retrans retransmissions instead of hanging forever.
# The app (plex) will fail to read the file — the node stays up.
# =============================================================================

resource "kubernetes_persistent_volume" "synology_docker" {
  metadata {
    name = "media-synology-docker"
  }
  spec {
    capacity = {
      storage = "10Ti"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    # "synology-nfs-static" is a static-only class (no provisioner).
    # Must match the PVC storage_class_name for Kubernetes to bind them.
    storage_class_name = "synology-nfs-static"
    mount_options      = ["soft", "timeo=150", "retrans=3"]
    persistent_volume_source {
      nfs {
        server = "192.168.1.10"
        path   = "/volume1/docker"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "synology_docker" {
  metadata {
    name      = "media-synology-docker"
    namespace = var.namespace
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "synology-nfs-static"
    volume_name        = kubernetes_persistent_volume.synology_docker.metadata[0].name
    resources {
      requests = {
        storage = "10Ti"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "synology_share" {
  metadata {
    name = "media-synology-share"
  }
  spec {
    capacity = {
      storage = "10Ti"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "synology-nfs-static"
    mount_options                    = ["soft", "timeo=150", "retrans=3"]
    persistent_volume_source {
      nfs {
        server = "192.168.1.10"
        path   = "/volume1/Share"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "synology_share" {
  metadata {
    name      = "media-synology-share"
    namespace = var.namespace
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "synology-nfs-static"
    volume_name        = kubernetes_persistent_volume.synology_share.metadata[0].name
    resources {
      requests = {
        storage = "10Ti"
      }
    }
  }
}

# =============================================================================
# Plex Media Server
# =============================================================================

resource "kubectl_manifest" "plex" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "plex"
      namespace = var.namespace
      labels    = local.plex_labels
    }
    spec = {
      replicas = 1
      # Singleton: only one pod can ever own the SQLite DB PVC and the GPU.
      strategy = { type = "Recreate" }
      selector = { matchLabels = local.plex_labels }
      template = {
        metadata = {
          labels      = local.plex_labels
          annotations = local.elastic_log_annotations
        }
        spec = {
          securityContext = {
            fsGroup             = 997
            fsGroupChangePolicy = "OnRootMismatch"
          }

          resourceClaims = [{
            name              = "gpu"
            resourceClaimName = "hestia-gpu"
          }]

          # Init container to restore databases from MinIO snapshots
          # CRITICAL: Plex MUST NOT start without a valid database
          initContainers = [{
            name    = "db-restore"
            image   = "alpine:3.23"
            command = ["/bin/sh", "-c"]
            args = [join("", [
              "set -e\n",
              "DB_DIR=\"/data/Databases\"\n",
              "LIBRARY_DB=\"$DB_DIR/com.plexapp.plugins.library.db\"\n",
              "BLOBS_DB=\"$DB_DIR/com.plexapp.plugins.library.blobs.db\"\n",
              "mkdir -p \"$DB_DIR\"\n",
              "\n",
              "# Skip if databases already exist\n",
              "if [ -f \"$LIBRARY_DB\" ]; then\n",
              "  echo \"Databases already exist, skipping restore\"\n",
              "  exit 0\n",
              "fi\n",
              "\n",
              "echo \"No local database found - attempting restore from MinIO...\"\n",
              "echo \"CRITICAL: Plex will NOT start if restore fails\"\n",
              "\n",
              "# Install curl for S3 API access\n",
              "apk add --no-cache curl\n",
              "\n",
              "# Function to download latest backup from MinIO\n",
              "download_latest() {\n",
              "  local prefix=$1\n",
              "  local output=$2\n",
              "  \n",
              "  echo \"Finding latest backup for $prefix...\"\n",
              "  \n",
              "  # List objects and find the most recent one (use sed - alpine grep lacks -P)\n",
              "  LATEST=$(curl -sf \\\n",
              "    --aws-sigv4 \"aws:amz:us-east-1:s3\" \\\n",
              "    --user \"$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY\" \\\n",
              "    \"$MINIO_ENDPOINT/$BACKUP_BUCKET?prefix=$prefix&list-type=2\" \\\n",
              "    2>/dev/null | sed -n 's/.*<Key>\\([^<]*\\)<\\/Key>.*/\\1/p' | sort -r | head -1)\n",
              "  \n",
              "  if [ -z \"$LATEST\" ]; then\n",
              "    echo \"ERROR: No backup found for $prefix\"\n",
              "    return 1\n",
              "  fi\n",
              "  \n",
              "  echo \"Downloading: $LATEST\"\n",
              "  curl -sf \\\n",
              "    --aws-sigv4 \"aws:amz:us-east-1:s3\" \\\n",
              "    --user \"$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY\" \\\n",
              "    \"$MINIO_ENDPOINT/$BACKUP_BUCKET/$LATEST\" \\\n",
              "    -o \"$output\"\n",
              "  \n",
              "  if [ ! -f \"$output\" ]; then\n",
              "    echo \"ERROR: Download failed for $output\"\n",
              "    return 1\n",
              "  fi\n",
              "  \n",
              "  echo \"Downloaded: $(stat -c%s \\\"$output\\\") bytes\"\n",
              "  return 0\n",
              "}\n",
              "\n",
              "RESTORE_FAILED=0\n",
              "\n",
              "echo \"Restoring library database...\"\n",
              "if download_latest \"library/\" \"$LIBRARY_DB\"; then\n",
              "  echo \"Library database restored successfully\"\n",
              "else\n",
              "  echo \"ERROR: Library database restore failed!\"\n",
              "  RESTORE_FAILED=1\n",
              "fi\n",
              "\n",
              "echo \"Restoring blobs database...\"\n",
              "if download_latest \"blobs/\" \"$BLOBS_DB\"; then\n",
              "  echo \"Blobs database restored successfully\"\n",
              "else\n",
              "  echo \"ERROR: Blobs database restore failed!\"\n",
              "  RESTORE_FAILED=1\n",
              "fi\n",
              "\n",
              "# Final verification - BOTH databases must exist\n",
              "if [ ! -f \"$LIBRARY_DB\" ]; then\n",
              "  echo \"FATAL: Library database does not exist after restore attempt!\"\n",
              "  echo \"Plex cannot start without a valid database.\"\n",
              "  echo \"Please check MinIO connectivity and backup status.\"\n",
              "  exit 1\n",
              "fi\n",
              "\n",
              "if [ ! -f \"$BLOBS_DB\" ]; then\n",
              "  echo \"FATAL: Blobs database does not exist after restore attempt!\"\n",
              "  echo \"Plex cannot start without a valid database.\"\n",
              "  exit 1\n",
              "fi\n",
              "\n",
              "# Verify databases are not empty (minimum viable size check)\n",
              "LIBRARY_SIZE=$(stat -c%s \"$LIBRARY_DB\" 2>/dev/null || echo \"0\")\n",
              "BLOBS_SIZE=$(stat -c%s \"$BLOBS_DB\" 2>/dev/null || echo \"0\")\n",
              "\n",
              "if [ \"$LIBRARY_SIZE\" -lt 100000 ]; then\n",
              "  echo \"FATAL: Library database is too small ($LIBRARY_SIZE bytes) - likely corrupted!\"\n",
              "  echo \"Expected at least 100KB for a valid Plex database.\"\n",
              "  rm -f \"$LIBRARY_DB\" \"$BLOBS_DB\"\n",
              "  exit 1\n",
              "fi\n",
              "\n",
              "# Skip integrity checks due to Plex custom FTS tokenizer issues\n",
              "# Size check above is sufficient - backups created with sqlite3 .backup are reliable\n",
              "\n",
              "echo \"Restore complete - Library: $LIBRARY_SIZE bytes, Blobs: $BLOBS_SIZE bytes\"\n",
            ])]
            env = [
              {
                name      = "MINIO_ACCESS_KEY"
                valueFrom = { secretKeyRef = { name = "media-centre-secrets", key = "MINIO_ACCESS_KEY" } }
              },
              {
                name      = "MINIO_SECRET_KEY"
                valueFrom = { secretKeyRef = { name = "media-centre-secrets", key = "MINIO_SECRET_KEY" } }
              },
              { name = "MINIO_ENDPOINT", value = local.plex_backup_endpoint },
              { name = "BACKUP_BUCKET", value = local.plex_backup_bucket },
            ]
            volumeMounts = [{ name = "plex-data", mountPath = "/data" }]
            resources = {
              requests = { cpu = "100m", memory = "256Mi" }
              limits   = { memory = "512Mi" }
            }
          }]

          containers = [
            # Plex container
            {
              name  = "plex"
              image = "${var.plex_image}:${var.plex_tag}"
              ports = [{ containerPort = 32400, name = "plex" }]
              env = [
                { name = "TZ", value = "Europe/London" },
                { name = "PLEX_UID", value = "990" },
                { name = "PLEX_GID", value = "997" },
                { name = "CHANGE_CONFIG_DIR_OWNERSHIP", value = "false" },
              ]
              volumeMounts = [
                { name = "plex-config", mountPath = "/config", mountPropagation = "HostToContainer" },
                {
                  name      = "plex-data"
                  mountPath = "/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
                  subPath   = "Databases"
                },
                { name = "transcode", mountPath = "/transcode" },
                { name = "tmp", mountPath = "/tmp" },
                { name = "media-docker", mountPath = "/data" },
                { name = "media-share", mountPath = "/share" },
              ]
              resources = {
                requests = { cpu = "100m", memory = "300Mi" }
                limits   = { cpu = "4", memory = "4Gi" }
                claims   = [{ name = "gpu" }]
              }
              livenessProbe = {
                httpGet             = { path = "/identity", port = 32400 }
                initialDelaySeconds = 60
                periodSeconds       = 30
                failureThreshold    = 5
              }
            }
          ]

          # Volumes
          volumes = [
            {
              name                  = "plex-config"
              persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.plex_config.metadata[0].name }
            },
            { name = "transcode", emptyDir = {} },
            { name = "tmp", emptyDir = {} },
            # Synology NAS volumes — via PVs with soft mount option
            {
              name                  = "media-docker"
              persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.synology_docker.metadata[0].name }
            },
            {
              name                  = "media-share"
              persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.synology_share.metadata[0].name }
            },
            # SQLite databases — standalone PVC on hestia's local-path.
            {
              name                  = "plex-data"
              persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.plex_data.metadata[0].name }
            },
          ]
        }
      }
    }
  })

  depends_on = [
    kubernetes_persistent_volume_claim.plex_config,
    kubernetes_persistent_volume_claim.plex_data,
  ]
}

resource "kubernetes_service" "plex" {
  metadata {
    name      = "plex"
    namespace = var.namespace
    labels    = local.plex_labels
  }

  spec {
    selector = local.plex_labels

    port {
      port        = 32400
      target_port = 32400
      name        = "plex"
    }
  }
}

resource "kubectl_manifest" "plex_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "plex"
      namespace = var.namespace
      labels    = local.plex_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`plex.brmartin.co.uk`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.plex.metadata[0].name
              port = 32400
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
# Plex Database Backup CronJob
# =============================================================================
# Periodic sqlite3 .backup to MinIO - corruption-safe even during writes
# Keeps last 48 backups (24 hours at 30-min intervals)

resource "kubernetes_cron_job_v1" "plex_db_backup" {
  metadata {
    name      = "plex-db-backup"
    namespace = var.namespace
    labels = {
      app        = "media-centre"
      component  = "plex-backup"
      managed-by = "terraform"
    }
  }

  spec {
    schedule                      = "*/30 * * * *" # Every 30 minutes
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = {
          app        = "media-centre"
          component  = "plex-backup"
          managed-by = "terraform"
        }
      }

      spec {
        ttl_seconds_after_finished = 3600
        backoff_limit              = 2

        template {
          metadata {
            labels = {
              app        = "media-centre"
              component  = "plex-backup"
              managed-by = "terraform"
            }
          }

          spec {
            restart_policy = "Never"

            # Must run on Hestia where the PVC is located
            node_selector = {
              "kubernetes.io/hostname" = "hestia"
            }

            container {
              name  = "backup"
              image = "alpine:3.23"

              command = ["/bin/sh", "-c"]
              args = [<<-EOF
                set -e
                echo "=== Plex Database Backup - $(date -Iseconds) ==="
                
                # Install required tools
                apk add --no-cache sqlite curl
                
                DB_DIR="/plex-data/Databases"
                LIBRARY_DB="$DB_DIR/com.plexapp.plugins.library.db"
                BLOBS_DB="$DB_DIR/com.plexapp.plugins.library.blobs.db"
                TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                
                # Verify source databases exist
                if [ ! -f "$LIBRARY_DB" ]; then
                  echo "ERROR: Library database not found at $LIBRARY_DB"
                  exit 1
                fi
                
                if [ ! -f "$BLOBS_DB" ]; then
                  echo "ERROR: Blobs database not found at $BLOBS_DB"
                  exit 1
                fi
                
                # Function to backup a database
                backup_db() {
                  local src=$1
                  local name=$2
                  local backup_file="/tmp/$${name}-$${TIMESTAMP}.db"
                  local s3_key="$name/$${name}-$${TIMESTAMP}.db"
                  
                  echo "Backing up $name..."
                  
                  # sqlite3 .backup is atomic and safe during writes
                  # It acquires a read lock and copies consistently
                  if ! sqlite3 "$src" ".backup '$backup_file'"; then
                    echo "ERROR: sqlite3 backup failed for $name"
                    return 1
                  fi
                  
                  # sqlite3 .backup is atomic and reliable - just verify file size
                  # Skip integrity checks due to Plex custom FTS tokenizer issues
                  local size=$(stat -c%s "$backup_file")
                  if [ "$size" -lt 10000 ]; then
                    echo "ERROR: Backup too small ($size bytes) for $name"
                    rm -f "$backup_file"
                    return 1
                  fi
                  echo "Backup created: $size bytes"
                  
                  # Upload to MinIO using S3 API with AWS SigV4
                  echo "Uploading to MinIO: $s3_key"
                  if ! curl -sf -X PUT \
                    --aws-sigv4 "aws:amz:us-east-1:s3" \
                    --user "$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY" \
                    -H "Content-Type: application/octet-stream" \
                    --data-binary "@$backup_file" \
                    "$MINIO_ENDPOINT/$BACKUP_BUCKET/$s3_key"; then
                    echo "ERROR: Upload failed for $name"
                    rm -f "$backup_file"
                    return 1
                  fi
                  
                  rm -f "$backup_file"
                  echo "$name backup complete: $s3_key"
                  return 0
                }
                
                # Function to cleanup old backups (keep last N)
                cleanup_old_backups() {
                  local prefix=$1
                  local keep=$2
                  
                  echo "Cleaning up old backups for $prefix (keeping last $keep)..."
                  
                  # List all objects with prefix (use sed - busybox grep lacks -P)
                  OBJECTS=$(curl -sf \
                    --aws-sigv4 "aws:amz:us-east-1:s3" \
                    --user "$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY" \
                    "$MINIO_ENDPOINT/$BACKUP_BUCKET?prefix=$prefix&list-type=2" \
                    2>/dev/null | sed -n 's/.*<Key>\([^<]*\)<\/Key>.*/\1/p' | sort -r)
                  
                  # Skip the first N (newest), delete the rest
                  echo "$OBJECTS" | tail -n +$((keep + 1)) | while read key; do
                    if [ -n "$key" ]; then
                      echo "Deleting old backup: $key"
                      curl -sf -X DELETE \
                        --aws-sigv4 "aws:amz:us-east-1:s3" \
                        --user "$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY" \
                        "$MINIO_ENDPOINT/$BACKUP_BUCKET/$key" || true
                    fi
                  done
                }
                
                # Perform backups
                FAILED=0
                
                backup_db "$LIBRARY_DB" "library" || FAILED=1
                backup_db "$BLOBS_DB" "blobs" || FAILED=1
                
                if [ "$FAILED" -eq 1 ]; then
                  echo "ERROR: One or more backups failed!"
                  exit 1
                fi
                
                # Cleanup old backups (keep last 48 = 24 hours at 30-min intervals)
                cleanup_old_backups "library/" 48
                cleanup_old_backups "blobs/" 48
                
                echo "=== Backup complete ==="
              EOF
              ]

              env {
                name = "MINIO_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = "media-centre-secrets"
                    key  = "MINIO_ACCESS_KEY"
                  }
                }
              }

              env {
                name = "MINIO_SECRET_KEY"
                value_from {
                  secret_key_ref {
                    name = "media-centre-secrets"
                    key  = "MINIO_SECRET_KEY"
                  }
                }
              }

              env {
                name  = "MINIO_ENDPOINT"
                value = local.plex_backup_endpoint
              }

              env {
                name  = "BACKUP_BUCKET"
                value = local.plex_backup_bucket
              }

              volume_mount {
                name       = "plex-data"
                mount_path = "/plex-data"
                read_only  = true
              }

              resources {
                requests = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
                limits = {
                  cpu    = "500m"
                  memory = "512Mi"
                }
              }
            }

            volume {
              name = "plex-data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.plex_data.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Tautulli (Plex Monitoring)
# =============================================================================

resource "kubernetes_deployment" "tautulli" {
  metadata {
    name      = "tautulli"
    namespace = var.namespace
    labels    = local.tautulli_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.tautulli_labels
    }

    template {
      metadata {
        labels      = local.tautulli_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        container {
          name  = "tautulli"
          image = "${var.tautulli_image}:${var.tautulli_tag}"

          port {
            container_port = 8181
            name           = "http"
          }

          env {
            name  = "PUID"
            value = "994"
          }

          env {
            name  = "PGID"
            value = "997"
          }

          env {
            name  = "TZ"
            value = "Europe/London"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/status"
              port = 8181
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/status"
              port = 8181
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          host_path {
            path = var.tautulli_config_path
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "tautulli" {
  metadata {
    name      = "tautulli"
    namespace = var.namespace
    labels    = local.tautulli_labels
  }

  spec {
    selector = local.tautulli_labels

    port {
      port        = 8181
      target_port = 8181
      name        = "http"
    }
  }
}

resource "kubectl_manifest" "tautulli_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "tautulli"
      namespace = var.namespace
      labels    = local.tautulli_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`tautulli.brmartin.co.uk`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.tautulli.metadata[0].name
              port = 8181
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

# Media centre secrets are managed outside Terraform as a plain Kubernetes Secret.
# Secret name: media-centre-secrets
# Keys: MINIO_ACCESS_KEY, MINIO_SECRET_KEY
