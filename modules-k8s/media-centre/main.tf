# Media Centre - Plex, Jellyfin, Tautulli
#
# Components:
# - Plex: Media server with NVIDIA GPU transcoding, periodic sqlite backup
# - Jellyfin: Alternative media server
# - Tautulli: Plex monitoring/statistics
#
# Requirements:
# - NVIDIA GPU on Hestia node (for Plex transcoding)
# - NFS access to Synology NAS (192.168.1.10) for media files
# - MinIO for database backups

locals {
  plex_labels = {
    app        = "media-centre"
    component  = "plex"
    managed-by = "terraform"
  }
  jellyfin_labels = {
    app        = "media-centre"
    component  = "jellyfin"
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
  plex_backup_endpoint = "http://minio-api.default.svc.cluster.local:9000"
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "plex_config" {
  metadata {
    name      = "plex-config"
    namespace = var.namespace
    annotations = {
      "volume-name" = "plex_config"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "jellyfin_config" {
  metadata {
    name      = "jellyfin-config"
    namespace = var.namespace
    annotations = {
      "volume-name" = "jellyfin_config"
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

# =============================================================================
# Synology NAS NFS PersistentVolumes (soft mount)
#
# Inline nfs{} volumes in pod specs use kernel-default 'hard' mounts.
# A hard mount blocks kernel NFS threads indefinitely when the NAS is
# unreachable, which starves the node network stack and causes crashes.
#
# PVs with mount_options = ["soft"] cause the kernel to return EIO to the
# application after retrans retransmissions instead of hanging forever.
# The app (plex/jellyfin) will fail to read the file — the node stays up.
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
    mount_options      = ["soft"]
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
    mount_options                    = ["soft"]
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

resource "kubernetes_stateful_set" "plex" {
  metadata {
    name      = "plex"
    namespace = var.namespace
    labels    = local.plex_labels
  }

  spec {
    service_name = "plex"
    replicas     = 1

    selector {
      match_labels = local.plex_labels
    }

    template {
      metadata {
        labels      = local.plex_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        # Must run on Hestia for NVIDIA GPU
        node_selector = {
          "kubernetes.io/hostname" = "hestia"
        }

        # Use NVIDIA runtime for GPU transcoding
        runtime_class_name = "nvidia"

        security_context {
          fs_group = 997 # video group for GPU access
        }

        # Init container to restore databases from MinIO snapshots
        # CRITICAL: Plex MUST NOT start without a valid database
        init_container {
          name  = "db-restore"
          image = "alpine:3.23"

          command = ["/bin/sh", "-c"]
          args = [<<-EOF
            set -e
            DB_DIR="/data/Databases"
            LIBRARY_DB="$DB_DIR/com.plexapp.plugins.library.db"
            BLOBS_DB="$DB_DIR/com.plexapp.plugins.library.blobs.db"
            mkdir -p "$DB_DIR"

            # Skip if databases already exist
            if [ -f "$LIBRARY_DB" ]; then
              echo "Databases already exist, skipping restore"
              exit 0
            fi

            echo "No local database found - attempting restore from MinIO..."
            echo "CRITICAL: Plex will NOT start if restore fails"

            # Install curl for S3 API access
            apk add --no-cache curl

            # Function to download latest backup from MinIO
            download_latest() {
              local prefix=$1
              local output=$2
              
              echo "Finding latest backup for $prefix..."
              
              # List objects and find the most recent one (use sed - alpine grep lacks -P)
              LATEST=$(curl -sf \
                --aws-sigv4 "aws:amz:us-east-1:s3" \
                --user "$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY" \
                "$MINIO_ENDPOINT/$BACKUP_BUCKET?prefix=$prefix&list-type=2" \
                2>/dev/null | sed -n 's/.*<Key>\([^<]*\)<\/Key>.*/\1/p' | sort -r | head -1)
              
              if [ -z "$LATEST" ]; then
                echo "ERROR: No backup found for $prefix"
                return 1
              fi
              
              echo "Downloading: $LATEST"
              curl -sf \
                --aws-sigv4 "aws:amz:us-east-1:s3" \
                --user "$MINIO_ACCESS_KEY:$MINIO_SECRET_KEY" \
                "$MINIO_ENDPOINT/$BACKUP_BUCKET/$LATEST" \
                -o "$output"
              
              if [ ! -f "$output" ]; then
                echo "ERROR: Download failed for $output"
                return 1
              fi
              
              echo "Downloaded: $(stat -c%s "$output") bytes"
              return 0
            }

            RESTORE_FAILED=0

            echo "Restoring library database..."
            if download_latest "library/" "$LIBRARY_DB"; then
              echo "Library database restored successfully"
            else
              echo "ERROR: Library database restore failed!"
              RESTORE_FAILED=1
            fi

            echo "Restoring blobs database..."
            if download_latest "blobs/" "$BLOBS_DB"; then
              echo "Blobs database restored successfully"
            else
              echo "ERROR: Blobs database restore failed!"
              RESTORE_FAILED=1
            fi

            # Final verification - BOTH databases must exist
            if [ ! -f "$LIBRARY_DB" ]; then
              echo "FATAL: Library database does not exist after restore attempt!"
              echo "Plex cannot start without a valid database."
              echo "Please check MinIO connectivity and backup status."
              exit 1
            fi

            if [ ! -f "$BLOBS_DB" ]; then
              echo "FATAL: Blobs database does not exist after restore attempt!"
              echo "Plex cannot start without a valid database."
              exit 1
            fi

            # Verify databases are not empty (minimum viable size check)
            LIBRARY_SIZE=$(stat -c%s "$LIBRARY_DB" 2>/dev/null || echo "0")
            BLOBS_SIZE=$(stat -c%s "$BLOBS_DB" 2>/dev/null || echo "0")
            
            if [ "$LIBRARY_SIZE" -lt 100000 ]; then
              echo "FATAL: Library database is too small ($LIBRARY_SIZE bytes) - likely corrupted!"
              echo "Expected at least 100KB for a valid Plex database."
              rm -f "$LIBRARY_DB" "$BLOBS_DB"
              exit 1
            fi

            # Skip integrity checks due to Plex custom FTS tokenizer issues
            # Size check above is sufficient - backups created with sqlite3 .backup are reliable

            chown -R 990:997 "$DB_DIR" 2>/dev/null || true
            echo "Restore complete - Library: $${LIBRARY_SIZE} bytes, Blobs: $${BLOBS_SIZE} bytes"
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
            mount_path = "/data"
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
        }

        # Plex container
        container {
          name  = "plex"
          image = "${var.plex_image}:${var.plex_tag}"

          port {
            container_port = 32400
            name           = "plex"
          }

          env {
            name  = "TZ"
            value = "Europe/London"
          }

          env {
            name  = "PLEX_UID"
            value = "990"
          }

          env {
            name  = "PLEX_GID"
            value = "997"
          }

          env {
            name  = "CHANGE_CONFIG_DIR_OWNERSHIP"
            value = "false"
          }

          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "all"
          }

          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "all"
          }

          volume_mount {
            name       = "plex-config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "plex-data"
            mount_path = "/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
            sub_path   = "Databases"
          }

          volume_mount {
            name       = "transcode"
            mount_path = "/transcode"
          }

          volume_mount {
            name       = "media-docker"
            mount_path = "/data"
          }

          volume_mount {
            name       = "media-share"
            mount_path = "/share"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "700Mi"
            }
            limits = {
              cpu              = "4"
              memory           = "4Gi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/identity"
              port = 32400
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 5
          }
        }

        # Volumes
        volume {
          name = "plex-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.plex_config.metadata[0].name
          }
        }

        volume {
          name = "transcode"
          empty_dir {}
        }

        # Synology NAS volumes — via PVs with soft mount option
        volume {
          name = "media-docker"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.synology_docker.metadata[0].name
          }
        }

        volume {
          name = "media-share"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.synology_share.metadata[0].name
          }
        }
      }
    }

    # Persistent volume for Plex databases
    volume_claim_template {
      metadata {
        name = "plex-data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "local-path"
        resources {
          requests = {
            storage = "2Gi"
          }
        }
      }
    }
  }

  depends_on = [
    kubectl_manifest.external_secret,
    kubernetes_persistent_volume_claim.plex_config,
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
                claim_name = "plex-data-plex-0"
              }
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Jellyfin Media Server
# =============================================================================

resource "kubernetes_deployment" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = var.namespace
    labels    = local.jellyfin_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.jellyfin_labels
    }

    template {
      metadata {
        labels      = local.jellyfin_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        security_context {
          fs_group            = 997 # video group
          supplemental_groups = [997]
        }

        container {
          name  = "jellyfin"
          image = "${var.jellyfin_image}:${var.jellyfin_tag}"

          port {
            container_port = 8096
            name           = "http"
          }

          env {
            name  = "JELLYFIN_PublishedServerUrl"
            value = "https://jellyfin.brmartin.co.uk"
          }

          volume_mount {
            name       = "jellyfin-config"
            mount_path = "/config"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }

          volume_mount {
            name       = "media"
            mount_path = "/media"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "700Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8096
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8096
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          security_context {
            privileged = true # Required for /dev/dri access
          }
        }

        volume {
          name = "jellyfin-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.jellyfin_config.metadata[0].name
          }
        }

        volume {
          name = "cache"
          empty_dir {
            size_limit = "4Gi"
          }
        }

        volume {
          name = "media"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.synology_docker.metadata[0].name
          }
        }

        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = var.namespace
    labels    = local.jellyfin_labels
  }

  spec {
    selector = local.jellyfin_labels

    port {
      port        = 8096
      target_port = 8096
      name        = "http"
    }
  }
}

resource "kubectl_manifest" "jellyfin_ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "jellyfin"
      namespace = var.namespace
      labels    = local.jellyfin_labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`jellyfin.brmartin.co.uk`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.jellyfin.metadata[0].name
              port = 8096
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

# =============================================================================
# External Secret for MinIO credentials
# =============================================================================

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "media-centre-secrets"
      namespace = var.namespace
      labels = {
        app        = "media-centre"
        managed-by = "terraform"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "media-centre-secrets"
      }
      data = [
        {
          secretKey = "MINIO_ACCESS_KEY"
          remoteRef = {
            key      = "nomad/default/media-centre"
            property = "MINIO_ACCESS_KEY"
          }
        },
        {
          secretKey = "MINIO_SECRET_KEY"
          remoteRef = {
            key      = "nomad/default/media-centre"
            property = "MINIO_SECRET_KEY"
          }
        }
      ]
    }
  })
}
