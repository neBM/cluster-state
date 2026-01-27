locals {
  app_name  = var.app_name
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/instance"   = local.app_name
    "app.kubernetes.io/component"  = "monitoring"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

resource "kubernetes_config_map" "prometheus_config" {
  metadata {
    name      = "${local.app_name}-config"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "prometheus.yml" = yamlencode({
      global = {
        scrape_interval     = var.scrape_interval
        evaluation_interval = var.scrape_interval
        scrape_timeout      = "10s"
      }

      scrape_configs = [
        {
          job_name = "prometheus"
          static_configs = [{
            targets = ["localhost:9090"]
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
resource "kubernetes_persistent_volume_claim" "prometheus_data" {
  wait_until_bound = false

  metadata {
    name      = "${local.app_name}-data"
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "volume-name" = "${local.app_name}_data"
    }
  }

  spec {
    storage_class_name = var.storage_class
    access_modes       = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}
resource "kubernetes_deployment" "prometheus" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

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
          "prometheus.io/port"   = "9090"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.prometheus.metadata[0].name

        # Prefer running on Hestia (amd64, more resources)
        affinity {
          node_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              preference {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = [var.node_affinity_hostname]
                }
              }
            }
          }
        }

        container {
          name  = local.app_name
          image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=${var.retention_days}d",
            "--web.console.libraries=/usr/share/prometheus/console_libraries",
            "--web.console.templates=/usr/share/prometheus/consoles",
            "--web.enable-lifecycle"
          ]

          port {
            name           = "http"
            container_port = 9090
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
            mount_path = "/etc/prometheus"
            read_only  = true
          }

          volume_mount {
            name       = "data"
            mount_path = "/prometheus"
          }

          liveness_probe {
            http_get {
              path = "/-/healthy"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/-/ready"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.prometheus_config.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prometheus_data.metadata[0].name
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "prometheus" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9090"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "http"
      port        = 9090
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

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
              name = kubernetes_service.prometheus.metadata[0].name
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