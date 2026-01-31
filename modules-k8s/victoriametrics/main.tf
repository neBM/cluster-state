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
  backup_dest = "s3://${var.minio_bucket}"
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
      
      BACKUP_INTERVAL="${var.backup_interval}"
      DATA_PATH="${local.data_path}"
      BACKUP_DEST="${local.backup_dest}"
      MINIO_ENDPOINT="${var.minio_endpoint}"
      
      echo "Starting vmbackup sidecar"
      echo "  Data path: $DATA_PATH"
      echo "  Backup destination: $BACKUP_DEST"
      echo "  MinIO endpoint: $MINIO_ENDPOINT"
      echo "  Backup interval: $BACKUP_INTERVAL"
      
      # Convert interval to seconds
      case "$BACKUP_INTERVAL" in
        *h) SLEEP_SECONDS=$((${replace(var.backup_interval, "h", "")} * 3600)) ;;
        *m) SLEEP_SECONDS=$((${replace(var.backup_interval, "m", "")} * 60)) ;;
        *)  SLEEP_SECONDS=3600 ;;
      esac
      
      echo "Sleeping $SLEEP_SECONDS seconds between backups"
      
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
        sleep $SLEEP_SECONDS
      done
    EOT

    "restore.sh" = <<-EOT
      #!/bin/sh
      set -e
      
      DATA_PATH="${local.data_path}"
      BACKUP_SRC="${local.backup_dest}"
      MINIO_ENDPOINT="${var.minio_endpoint}"
      
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
      fi
    EOT
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
        }
      }

      spec {
        service_account_name = kubernetes_service_account.victoriametrics.metadata[0].name

        # Init container: restore from MinIO backup
        init_container {
          name  = "vmrestore"
          image = "victoriametrics/vmrestore:${var.image_tag}"

          command = ["/bin/sh", "/scripts/restore.sh"]

          env_from {
            secret_ref {
              name = var.minio_secret_name
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

        # Sidecar container: vmbackup (periodic backups to MinIO)
        container {
          name  = "vmbackup"
          image = "victoriametrics/vmbackup:${var.image_tag}"

          command = ["/bin/sh", "/scripts/backup.sh"]

          env_from {
            secret_ref {
              name = var.minio_secret_name
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

        # emptyDir for data - fast local storage, restored from MinIO on startup
        volume {
          name = "data"
          empty_dir {
            size_limit = "20Gi"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.scrape_config,
    kubernetes_config_map.backup_script,
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
