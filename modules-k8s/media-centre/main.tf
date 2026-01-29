# Media Centre - Plex, Jellyfin, Tautulli
#
# Components:
# - Plex: Media server with NVIDIA GPU transcoding, litestream backup
# - Jellyfin: Alternative media server
# - Tautulli: Plex monitoring/statistics
#
# Requirements:
# - NVIDIA GPU on Hestia node (for Plex transcoding)
# - NFS access to Synology NAS (192.168.1.10) for media files
# - MinIO for litestream backups

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
}

# =============================================================================
# Plex Media Server
# =============================================================================

resource "kubernetes_config_map" "plex_litestream" {
  metadata {
    name      = "plex-litestream-config"
    namespace = var.namespace
    labels    = local.plex_labels
  }

  data = {
    "litestream.yml" = yamlencode({

      dbs = [
        {
          path = "/data/Databases/com.plexapp.plugins.library.db"
          replicas = [
            {
              name                     = "library"
              type                     = "s3"
              bucket                   = "plex-litestream"
              path                     = "library"
              endpoint                 = "http://minio-api.default.svc.cluster.local:9000"
              force-path-style         = true
              sync-interval            = "5m"
              snapshot-interval        = "1h"
              retention                = "168h"
              retention-check-interval = "1h"
            }
          ]
        },
        {
          path = "/data/Databases/com.plexapp.plugins.library.blobs.db"
          replicas = [
            {
              name                     = "blobs"
              type                     = "s3"
              bucket                   = "plex-litestream"
              path                     = "blobs"
              endpoint                 = "http://minio-api.default.svc.cluster.local:9000"
              force-path-style         = true
              sync-interval            = "5m"
              snapshot-interval        = "1h"
              retention                = "168h"
              retention-check-interval = "1h"
            }
          ]
        }
      ]
    })
  }
}

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

        # Init container to restore databases from litestream
        # Using 0.5 for restore as it supports the older LTX format used in existing backups
        # CRITICAL: Plex MUST NOT start without a valid database - either pre-existing or restored
        init_container {
          name  = "litestream-restore"
          image = "litestream/litestream:0.5"

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

            echo "No local database found - attempting restore from S3..."
            echo "CRITICAL: Plex will NOT start if restore fails to prevent empty database creation"
            
            # Create litestream config with credentials
            cat > /tmp/litestream.yml << LSEOF
            dbs:
              - path: $LIBRARY_DB
                replicas:
                  - name: library
                    type: s3
                    bucket: plex-litestream
                    path: library
                    endpoint: http://minio-api.default.svc.cluster.local:9000
                    access-key-id: $MINIO_ACCESS_KEY
                    secret-access-key: $MINIO_SECRET_KEY
                    force-path-style: true
              - path: $BLOBS_DB
                replicas:
                  - name: blobs
                    type: s3
                    bucket: plex-litestream
                    path: blobs
                    endpoint: http://minio-api.default.svc.cluster.local:9000
                    access-key-id: $MINIO_ACCESS_KEY
                    secret-access-key: $MINIO_SECRET_KEY
                    force-path-style: true
            LSEOF

            RESTORE_FAILED=0

            echo "Restoring library database..."
            if litestream restore -config /tmp/litestream.yml -o "$LIBRARY_DB" "$LIBRARY_DB"; then
              echo "Library database restored successfully"
            else
              echo "ERROR: Library database restore failed!"
              RESTORE_FAILED=1
            fi

            echo "Restoring blobs database..."
            if litestream restore -config /tmp/litestream.yml -o "$BLOBS_DB" "$BLOBS_DB"; then
              echo "Blobs database restored successfully"
            else
              echo "ERROR: Blobs database restore failed!"
              RESTORE_FAILED=1
            fi

            # Final verification - BOTH databases must exist
            if [ ! -f "$LIBRARY_DB" ]; then
              echo "FATAL: Library database does not exist after restore attempt!"
              echo "Plex cannot start without a valid database."
              echo "Please check MinIO connectivity and litestream backup status."
              exit 1
            fi

            if [ ! -f "$BLOBS_DB" ]; then
              echo "FATAL: Blobs database does not exist after restore attempt!"
              echo "Plex cannot start without a valid database."
              echo "Please check MinIO connectivity and litestream backup status."
              exit 1
            fi

            # Verify databases are not empty (minimum viable size check)
            LIBRARY_SIZE=$(stat -c%s "$LIBRARY_DB" 2>/dev/null || echo "0")
            BLOBS_SIZE=$(stat -c%s "$BLOBS_DB" 2>/dev/null || echo "0")
            
            if [ "$LIBRARY_SIZE" -lt 100000 ]; then
              echo "FATAL: Library database is too small ($LIBRARY_SIZE bytes) - likely corrupted or empty!"
              echo "Expected at least 100KB for a valid Plex database."
              rm -f "$LIBRARY_DB" "$BLOBS_DB"
              exit 1
            fi

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
              cpu    = "1500m"  # goldilocks recommends 1554m
              memory = "1Gi"
            }
            limits = {
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
            # Plex returns 401 for unauthenticated but that confirms it's running
            failure_threshold = 5
          }
        }

        # Litestream sidecar for continuous replication
        # Using 0.5 for LTX format compatibility with existing backups
        container {
          name  = "litestream"
          image = "litestream/litestream:0.5"
          args  = ["replicate", "-config", "/etc/litestream/litestream.yml"]

          env {
            name = "LITESTREAM_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = "media-centre-secrets"
                key  = "MINIO_ACCESS_KEY"
              }
            }
          }

          env {
            name = "LITESTREAM_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = "media-centre-secrets"
                key  = "MINIO_SECRET_KEY"
              }
            }
          }

          volume_mount {
            name       = "plex-data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "litestream-config"
            mount_path = "/etc/litestream"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              # Increased from 512Mi - litestream 0.5.x uses excessive memory
              # during L1 compaction with large databases (129MB Plex library.db)
              memory = "2Gi"
            }
          }
        }

        # Volumes
        volume {
          name = "plex-config"
          host_path {
            path = var.plex_config_path
            type = "Directory"
          }
        }

        volume {
          name = "transcode"
          empty_dir {
            medium     = "Memory"
            size_limit = "4Gi"
          }
        }

        volume {
          name = "litestream-config"
          config_map {
            name = kubernetes_config_map.plex_litestream.metadata[0].name
          }
        }

        # NFS mounts to Synology NAS
        volume {
          name = "media-docker"
          nfs {
            server = "192.168.1.10"
            path   = "/volume1/docker"
          }
        }

        volume {
          name = "media-share"
          nfs {
            server = "192.168.1.10"
            path   = "/volume1/Share"
          }
        }
      }
    }

    # Persistent volume for Plex databases (ephemeral in Nomad, but stateful here)
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

  depends_on = [kubectl_manifest.external_secret]
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

          # GPU access for hardware transcoding
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "512Mi"
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
          host_path {
            path = var.jellyfin_config_path
            type = "Directory"
          }
        }

        volume {
          name = "cache"
          empty_dir {
            medium     = "Memory"
            size_limit = "4Gi"
          }
        }

        volume {
          name = "media"
          nfs {
            server = "192.168.1.10"
            path   = "/volume1/docker"
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

# =============================================================================
# Litestream LTX Cleanup CronJob
# =============================================================================
# TEMPORARY WORKAROUND for litestream 0.5.x LTX file buildup issue
# GitHub Issues: #976, #994 - https://github.com/benbjohnson/litestream/issues/976
# Remove this resource when litestream fixes the issue (expected in v0.5.7+)
#
# This CronJob cleans up old .ltx files from the local shadow directory
# that litestream 0.5.x fails to delete, preventing disk exhaustion.

resource "kubernetes_cron_job_v1" "litestream_ltx_cleanup" {
  metadata {
    name      = "litestream-ltx-cleanup"
    namespace = var.namespace
    labels = {
      app        = "media-centre"
      component  = "litestream-cleanup"
      managed-by = "terraform"
      temporary  = "true" # Mark as temporary workaround
    }
    annotations = {
      "description"  = "Temporary workaround for litestream 0.5.x LTX buildup - remove when fixed upstream"
      "github-issue" = "https://github.com/benbjohnson/litestream/issues/976"
    }
  }

  spec {
    schedule                      = "0 */6 * * *" # Every 6 hours
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = {
          app        = "media-centre"
          component  = "litestream-cleanup"
          managed-by = "terraform"
        }
      }

      spec {
        ttl_seconds_after_finished = 3600 # Clean up job after 1 hour
        backoff_limit              = 1

        template {
          metadata {
            labels = {
              app        = "media-centre"
              component  = "litestream-cleanup"
              managed-by = "terraform"
            }
          }

          spec {
            restart_policy = "Never"

            # Must run on Hestia where the local-path PVC is located
            node_selector = {
              "kubernetes.io/hostname" = "hestia"
            }

            container {
              name  = "cleanup"
              image = "${var.busybox_image}:${var.busybox_tag}"

              command = ["/bin/sh", "-c"]
              args = [<<-EOF
                echo "=== Litestream LTX Cleanup - $(date) ==="
                echo "Target: $LTX_BASE_PATH"
                
                # Process each known litestream shadow directory
                # Plex has two databases: library.db and blobs.db
                for db_name in ".com.plexapp.plugins.library.db-litestream" ".com.plexapp.plugins.library.blobs.db-litestream"; do
                  db_dir="$LTX_BASE_PATH/Databases/$db_name/ltx/0"
                  if [ -d "$db_dir" ]; then
                    echo "Processing: $db_dir"
                    before=$(find "$db_dir" -name '*.ltx' -type f | wc -l)
                    
                    # Delete LTX files older than 60 minutes
                    find "$db_dir" -name '*.ltx' -type f -mmin +60 -delete || true
                    
                    after=$(find "$db_dir" -name '*.ltx' -type f | wc -l)
                    deleted=$((before - after))
                    echo "  Before: $before, After: $after, Deleted: $deleted"
                  else
                    echo "Directory not found: $db_dir"
                  fi
                done
                
                echo "=== Cleanup complete ==="
              EOF
              ]

              env {
                name  = "LTX_BASE_PATH"
                value = "/plex-data"
              }

              volume_mount {
                name       = "plex-data"
                mount_path = "/plex-data"
              }

              resources {
                requests = {
                  cpu    = "10m"
                  memory = "16Mi"
                }
                limits = {
                  cpu    = "100m"
                  memory = "64Mi"
                }
              }
            }

            volume {
              name = "plex-data"
              host_path {
                # Path to Plex's local-path PVC on Hestia
                path = "/var/lib/rancher/k3s/storage/pvc-2fd10269-54e8-47b3-9454-0185744046aa_default_plex-data-plex-0"
                type = "Directory"
              }
            }
          }
        }
      }
    }
  }
}
