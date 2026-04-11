locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "monitoring"
    "app.kubernetes.io/managed-by" = "terraform"
  }
  data_path   = "/victoria-metrics-data"
  backup_dest = "s3://${var.s3_bucket}/data"

  # Convert backup_interval ("1h", "30m") to seconds at plan time so the
  # rendered shell script contains a plain integer instead of a runtime case.
  backup_sleep_seconds = (
    endswith(var.backup_interval, "h") ? tonumber(trimsuffix(var.backup_interval, "h")) * 3600 :
    endswith(var.backup_interval, "m") ? tonumber(trimsuffix(var.backup_interval, "m")) * 60 :
    3600
  )
}

# =============================================================================
# Scrape Configuration (Prometheus-compatible format)
# =============================================================================

resource "kubernetes_config_map" "scrape_config" {
  metadata {
    name      = "${local.app_name}-config"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "scrape.yml" = yamlencode({
      global = {
        scrape_interval = var.scrape_interval
      }

      scrape_configs = [
        # Self-monitoring
        {
          job_name = "victoriametrics"
          static_configs = [{
            targets = ["localhost:8428"]
          }]
        },

        # Kubernetes API server
        {
          job_name = "kubernetes-apiservers"
          kubernetes_sd_configs = [{
            role = "endpoints"
          }]
          scheme = "https"
          tls_config = {
            ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            insecure_skip_verify = true
          }
          bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
          relabel_configs = [
            {
              source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_service_name", "__meta_kubernetes_endpoint_port_name"]
              action        = "keep"
              regex         = "default;kubernetes;https"
            }
          ]
        },

        # Kubernetes nodes
        {
          job_name = "kubernetes-nodes"
          kubernetes_sd_configs = [{
            role = "node"
          }]
          scheme = "https"
          tls_config = {
            ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            insecure_skip_verify = true
          }
          bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
          relabel_configs = [
            {
              action = "labelmap"
              regex  = "__meta_kubernetes_node_label_(.+)"
            },
            {
              target_label = "__address__"
              replacement  = "kubernetes.default.svc:443"
            },
            {
              source_labels = ["__meta_kubernetes_node_name"]
              regex         = "(.+)"
              target_label  = "__metrics_path__"
              replacement   = "/api/v1/nodes/$${1}/proxy/metrics"
            }
          ]
        },

        # Kubernetes nodes cadvisor
        {
          job_name = "kubernetes-cadvisor"
          kubernetes_sd_configs = [{
            role = "node"
          }]
          scheme = "https"
          tls_config = {
            ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            insecure_skip_verify = true
          }
          bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
          relabel_configs = [
            {
              action = "labelmap"
              regex  = "__meta_kubernetes_node_label_(.+)"
            },
            {
              target_label = "__address__"
              replacement  = "kubernetes.default.svc:443"
            },
            {
              source_labels = ["__meta_kubernetes_node_name"]
              regex         = "(.+)"
              target_label  = "__metrics_path__"
              replacement   = "/api/v1/nodes/$${1}/proxy/metrics/cadvisor"
            }
          ]
        },

        # Service endpoints with prometheus.io/scrape annotation
        {
          job_name = "kubernetes-service-endpoints"
          kubernetes_sd_configs = [{
            role = "endpoints"
          }]
          relabel_configs = [
            {
              source_labels = ["__meta_kubernetes_service_annotation_prometheus_io_scrape"]
              action        = "keep"
              regex         = "true"
            },
            {
              source_labels = ["__meta_kubernetes_service_annotation_prometheus_io_path"]
              action        = "replace"
              target_label  = "__metrics_path__"
              regex         = "(.+)"
            },
            {
              source_labels = ["__address__", "__meta_kubernetes_service_annotation_prometheus_io_port"]
              action        = "replace"
              regex         = "([^:]+)(?::\\d+)?;(\\d+)"
              replacement   = "$${1}:$${2}"
              target_label  = "__address__"
            },
            {
              action = "labelmap"
              regex  = "__meta_kubernetes_service_label_(.+)"
            },
            {
              source_labels = ["__meta_kubernetes_namespace"]
              action        = "replace"
              target_label  = "kubernetes_namespace"
            },
            {
              source_labels = ["__meta_kubernetes_service_name"]
              action        = "replace"
              target_label  = "kubernetes_name"
            }
          ]
        },

        # Pods with prometheus.io/scrape annotation
        {
          job_name = "kubernetes-pods"
          kubernetes_sd_configs = [{
            role = "pod"
          }]
          relabel_configs = [
            {
              source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
              action        = "keep"
              regex         = "true"
            },
            {
              source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"]
              action        = "replace"
              target_label  = "__metrics_path__"
              regex         = "(.+)"
            },
            {
              source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"]
              action        = "replace"
              regex         = "([^:]+)(?::\\d+)?;(\\d+)"
              replacement   = "$${1}:$${2}"
              target_label  = "__address__"
            },
            {
              action = "labelmap"
              regex  = "__meta_kubernetes_pod_label_(.+)"
            },
            {
              source_labels = ["__meta_kubernetes_namespace"]
              action        = "replace"
              target_label  = "kubernetes_namespace"
            },
            {
              source_labels = ["__meta_kubernetes_pod_name"]
              action        = "replace"
              target_label  = "kubernetes_pod_name"
            }
          ]
        }
      ]
    })
  }
}

# =============================================================================
# Backup Script ConfigMap
# =============================================================================

resource "kubernetes_config_map" "backup_script" {
  metadata {
    name      = "${local.app_name}-backup-script"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "backup.sh" = <<-EOT
      #!/bin/sh
      set -e

      DATA_PATH="${local.data_path}"
      BACKUP_DEST="${local.backup_dest}"
      MINIO_ENDPOINT="${var.s3_endpoint}"
      SLEEP_SECONDS=${local.backup_sleep_seconds}

      # SIGTERM handling: /bin/sh as PID 1 ignores SIGTERM by default (the
      # kernel masks signals without handlers for PID 1), so without an
      # explicit trap the pod hangs until terminationGracePeriodSeconds
      # expires and kubelet SIGKILLs. The container preStop hook above has
      # already drained any in-flight vmbackup-prod before SIGTERM arrives,
      # so exiting immediately here is safe — the bucket is guaranteed
      # consistent at this point.
      trap 'echo "Received SIGTERM/INT, exiting"; exit 0' TERM INT

      echo "Starting vmbackup sidecar"
      echo "  Data path: $DATA_PATH"
      echo "  Backup destination: $BACKUP_DEST"
      echo "  MinIO endpoint: $MINIO_ENDPOINT"
      echo "  Backup interval: ${var.backup_interval} ($SLEEP_SECONDS seconds)"

      while true; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') Starting incremental backup..."
        
        /vmbackup-prod \
          -storageDataPath="$DATA_PATH" \
          -dst="$BACKUP_DEST" \
          -customS3Endpoint="$MINIO_ENDPOINT" \
          -snapshot.createURL="http://localhost:8428/snapshot/create" \
          -snapshot.deleteURL="http://localhost:8428/snapshot/delete" \
          || echo "Backup failed, will retry next interval"
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') Backup complete, sleeping $SLEEP_SECONDS seconds"
        # Background sleep + wait so the TERM trap above fires immediately
        # on SIGTERM. A direct "sleep $SLEEP_SECONDS" would block signal
        # delivery until sleep exits (up to the full interval).
        sleep "$SLEEP_SECONDS" &
        wait $!
      done
    EOT

    "restore.sh" = <<-EOT
      #!/bin/sh
      set -e
      
      DATA_PATH="${local.data_path}"
      BACKUP_SRC="${local.backup_dest}"
      MINIO_ENDPOINT="${var.s3_endpoint}"
      
      echo "Starting vmrestore"
      echo "  Data path: $DATA_PATH"
      echo "  Backup source: $BACKUP_SRC"
      echo "  MinIO endpoint: $MINIO_ENDPOINT"
      
      # Check if backup exists in MinIO
      if /vmrestore-prod \
           -src="$BACKUP_SRC" \
           -storageDataPath="$DATA_PATH" \
           -customS3Endpoint="$MINIO_ENDPOINT"; then
        echo "Restore complete"
      else
        echo "No backup found or restore failed - starting fresh"
        # Remove lock file left by vmrestore so VictoriaMetrics can start
        rm -f "$DATA_PATH/restore-in-progress"
      fi
    EOT
  }
}

# =============================================================================
# Persistent Volume Claim (local-path, late-binding)
# =============================================================================
# Uses a node-local PV rather than emptyDir so VM's TSDB survives pod restarts
# without a full vmrestore-from-S3 cycle. Late-binding: the PV is not created
# until the pod schedules, at which point local-path creates the directory on
# whichever node wins — pinned to hestia via node_selector on the Deployment.
#
# Durability story:
#   - Node-local disk: survives pod restart, rollout, eviction
#   - vmbackup sidecar → MinIO: survives node loss, disk loss (bounded RPO)

resource "kubernetes_persistent_volume_claim" "data" {
  # Late-binding StorageClass — PVC stays Pending until the pod mounts it.
  wait_until_bound = false

  metadata {
    name      = "${local.app_name}-data"
    namespace = local.namespace
    labels    = local.labels
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

# =============================================================================
# VictoriaMetrics Deployment
# =============================================================================

resource "kubernetes_deployment" "victoriametrics" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate" # Required for single-writer storage
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = local.app_name
        "app.kubernetes.io/instance" = local.app_name
      }
    }

    template {
      metadata {
        labels = merge(local.labels, {
          "app.kubernetes.io/version" = var.image_tag
        })
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8428"
          # Force a rolling update whenever backup.sh / restore.sh change.
          # Without this, ConfigMap edits propagate to the pod's /scripts
          # volume mount via kubelet sync, but the already-running sh process
          # keeps executing the OLD script from memory — fixes silently fail
          # to take effect until someone manually rolls. Keyed to the full
          # ConfigMap data so any script edit triggers a new ReplicaSet.
          "checksum/backup-script" = sha256(jsonencode(kubernetes_config_map.backup_script.data))
        }
      }

      spec {
        service_account_name = kubernetes_service_account.victoriametrics.metadata[0].name

        # Give vmbackup time to finish an in-flight run before SIGKILL.
        # vmbackup (Run() in lib/backup/actions/backup.go) atomically swaps the
        # `backup_complete.ignore` marker — it DELETES the marker at the start
        # of a run and RECREATES it at the end. vmbackup has no signal handler,
        # so SIGTERM kills the Go process immediately. If the pod is torn down
        # mid-run (e.g. terraform-driven rollout under the Recreate strategy),
        # the marker stays deleted and the next pod's vmrestore init container
        # sees "cannot find backup_complete.ignore" and starts fresh — silent
        # data loss on restore. The preStop hook on the sidecar below blocks
        # pod termination until vmbackup-prod is idle; this grace period must
        # exceed the longest expected backup duration. 600s is comfortable
        # headroom for the current ~20Gi storage size.
        termination_grace_period_seconds = 600

        # Init container: restore from S3 backup
        init_container {
          name  = "vmrestore"
          image = "victoriametrics/vmrestore:${var.image_tag}"

          command = ["/bin/sh", "/scripts/restore.sh"]

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

          volume_mount {
            name       = "data"
            mount_path = local.data_path
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
        }

        # Main container: VictoriaMetrics
        container {
          name  = "victoriametrics"
          image = "victoriametrics/victoria-metrics:${var.image_tag}"

          args = [
            "-storageDataPath=${local.data_path}",
            "-retentionPeriod=${var.retention_period}",
            "-promscrape.config=/config/scrape.yml",
            "-httpListenAddr=:8428",
            "-selfScrapeInterval=${var.scrape_interval}",
          ]

          port {
            name           = "http"
            container_port = 8428
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }

          volume_mount {
            name       = "data"
            mount_path = local.data_path
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        # Sidecar container: vmbackup (periodic backups to SeaweedFS S3)
        container {
          name  = "vmbackup"
          image = "victoriametrics/vmbackup:${var.image_tag}"

          command = ["/bin/sh", "/scripts/backup.sh"]

          # Block pod termination until any in-flight vmbackup-prod run
          # completes. vmbackup's Run() deletes `backup_complete.ignore` at
          # the start of a run and recreates it at the end — and vmbackup
          # has no signal handler, so a mid-run SIGTERM leaves the bucket
          # with the marker missing and the next vmrestore fails. Polling
          # pidof here holds the container until vmbackup-prod is no longer
          # running, at which point the bucket is in a consistent state and
          # kubelet may safely send SIGTERM. Bounded by the pod's
          # termination_grace_period_seconds above.
          lifecycle {
            pre_stop {
              exec {
                command = [
                  "/bin/sh",
                  "-c",
                  "echo 'preStop: waiting for vmbackup-prod to finish'; while pidof vmbackup-prod >/dev/null 2>&1; do sleep 1; done; echo 'preStop: vmbackup idle, allowing termination'",
                ]
              }
            }
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
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = local.data_path
            read_only  = true
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.scrape_config.metadata[0].name
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.backup_script.metadata[0].name
            default_mode = "0755"
          }
        }

        # Node-local PV — durable TSDB storage, survives pod restarts.
        # First boot: vmrestore init container populates from MinIO S3.
        # Subsequent restarts: PV already has data, vmrestore is a no-op.
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }

        # Pin to a specific node so the local-path provisioner creates the PV
        # directory deterministically. Required because local PVs are node-bound
        # — moving the pod after first bind would orphan the data.
        node_selector = var.node_selector
      }
    }
  }

  depends_on = [
    kubernetes_config_map.scrape_config,
    kubernetes_config_map.backup_script,
    kubernetes_persistent_volume_claim.data,
  ]
}

# =============================================================================
# Service
# =============================================================================

resource "kubernetes_service" "victoriametrics" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "8428"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "http"
      port        = 8428
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# IngressRoute (Traefik)
# =============================================================================

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = local.app_name
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.ingress_hostname}`)"
          kind  = "Rule"
          middlewares = var.traefik_middlewares != [] ? [
            for middleware in var.traefik_middlewares : {
              name      = middleware
              namespace = local.namespace
            }
          ] : null
          services = [
            {
              name = kubernetes_service.victoriametrics.metadata[0].name
              port = "http"
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
