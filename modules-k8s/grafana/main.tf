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

# ConfigMap for Prometheus datasource provisioning
resource "kubernetes_config_map" "datasources" {
  metadata {
    name      = "${local.app_name}-datasources"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "prometheus.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Prometheus"
          type      = "prometheus"
          uid       = "prometheus"
          access    = "proxy"
          url       = var.prometheus_url
          isDefault = true
          editable  = false
        }
      ]
    })
  }
}

# ConfigMap for dashboard provisioning configuration
resource "kubernetes_config_map" "dashboards" {
  metadata {
    name      = "${local.app_name}-dashboard-config"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "dashboards.yaml" = yamlencode({
      apiVersion = 1
      providers = [
        {
          name                  = "default"
          orgId                 = 1
          folder                = ""
          type                  = "file"
          disableDeletion       = false
          updateIntervalSeconds = 10
          allowUiUpdates        = false
          options = {
            path = "/var/lib/grafana/dashboards"
          }
        }
      ]
    })
  }
}

# ConfigMap for alert rule provisioning
resource "kubernetes_config_map" "alerting" {
  metadata {
    name      = "${local.app_name}-alerting"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "infrastructure-alerts.yaml" = yamlencode({
      apiVersion = 1
      groups = [
        {
          orgId    = 1
          name     = "node-health"
          folder   = "Infrastructure Alerts"
          interval = "1m"
          rules = [
            {
              # Per-node query so $labels.instance is populated.
              # noDataState=OK: empty result means all nodes are up (not an error).
              # Truly-gone nodes (stale series) are caught by Prometheus Target Down.
              uid          = "efbh005jfadxce"
              title        = "Node Down"
              condition    = "C"
              for          = "2m"
              noDataState  = "OK"
              execErrState = "Alerting"
              annotations = {
                summary     = "Node {{ $labels.instance }} is down"
                description = "node-exporter on {{ $labels.instance }} is reporting up=0."
              }
              labels = {
                severity = "critical"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 600
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "up{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\"} == 0"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "B"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    reducer    = "last"
                    refId      = "B"
                    type       = "reduce"
                    settings = {
                      mode = "dropNN"
                    }
                  }
                },
                {
                  refId         = "C"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    conditions = [
                      {
                        evaluator = {
                          params = [1]
                          type   = "lt"
                        }
                      }
                    ]
                    expression = "B"
                    refId      = "C"
                    type       = "threshold"
                  }
                }
              ]
            },
            {
              uid          = "bfbh005szwdmof"
              title        = "High Memory Usage"
              condition    = "C"
              for          = "5m"
              noDataState  = "OK"
              execErrState = "OK"
              annotations = {
                summary     = "High memory usage on {{ $labels.instance }}"
                description = "Memory usage on {{ $labels.instance }} has exceeded 90% for more than 5 minutes."
              }
              labels = {
                severity = "warning"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 600
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "B"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    reducer    = "last"
                    refId      = "B"
                    type       = "reduce"
                    settings = {
                      mode = "dropNN"
                    }
                  }
                },
                {
                  refId         = "C"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    conditions = [
                      {
                        evaluator = {
                          params = [90]
                          type   = "gt"
                        }
                      }
                    ]
                    expression = "B"
                    refId      = "C"
                    type       = "threshold"
                  }
                }
              ]
            },
            {
              uid          = "efbh005w6rpj4c"
              title        = "High CPU Usage"
              condition    = "C"
              for          = "10m"
              noDataState  = "OK"
              execErrState = "OK"
              annotations = {
                summary     = "High CPU usage on {{ $labels.instance }}"
                description = "CPU usage on {{ $labels.instance }} has exceeded 85% for more than 10 minutes."
              }
              labels = {
                severity = "warning"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 600
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "B"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    reducer    = "last"
                    refId      = "B"
                    type       = "reduce"
                    settings = {
                      mode = "dropNN"
                    }
                  }
                },
                {
                  refId         = "C"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    conditions = [
                      {
                        evaluator = {
                          params = [85]
                          type   = "gt"
                        }
                      }
                    ]
                    expression = "B"
                    refId      = "C"
                    type       = "threshold"
                  }
                }
              ]
            },
            {
              uid          = "cfbh00607ltkwb"
              title        = "Disk Space Low"
              condition    = "C"
              for          = "5m"
              noDataState  = "OK"
              execErrState = "OK"
              annotations = {
                summary     = "Low disk space on {{ $labels.instance }}"
                description = "Root filesystem on {{ $labels.instance }} has less than 15% free space."
              }
              labels = {
                severity = "critical"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 600
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "(node_filesystem_avail_bytes{mountpoint=\"/\",fstype!=\"tmpfs\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!=\"tmpfs\"}) * 100"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "B"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    reducer    = "last"
                    refId      = "B"
                    type       = "reduce"
                    settings = {
                      mode = "dropNN"
                    }
                  }
                },
                {
                  refId         = "C"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    conditions = [
                      {
                        evaluator = {
                          params = [15]
                          type   = "lt"
                        }
                      }
                    ]
                    expression = "B"
                    refId      = "C"
                    type       = "threshold"
                  }
                }
              ]
            }
          ]
        },
        {
          orgId    = 1
          name     = "pod-health"
          folder   = "Infrastructure Alerts"
          interval = "1m"
          rules = [
            {
              uid          = "afbh005pbjrb4b"
              title        = "Pod CrashLooping"
              condition    = "C"
              for          = "15m"
              noDataState  = "OK"
              execErrState = "OK"
              annotations = {
                summary     = "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash-looping"
                description = "Container {{ $labels.container }} in pod {{ $labels.namespace }}/{{ $labels.pod }} has restarted more than 3 times in 15 minutes."
              }
              labels = {
                severity = "warning"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 900
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "increase(kube_pod_container_status_restarts_total[15m])"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "B"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    reducer    = "last"
                    refId      = "B"
                    type       = "reduce"
                    settings = {
                      mode = "dropNN"
                    }
                  }
                },
                {
                  refId         = "C"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    conditions = [
                      {
                        evaluator = {
                          params = [3]
                          type   = "gt"
                        }
                      }
                    ]
                    expression = "B"
                    refId      = "C"
                    type       = "threshold"
                  }
                }
              ]
            }
          ]
        },
        {
          orgId    = 1
          name     = "prometheus-health"
          folder   = "Infrastructure Alerts"
          interval = "1m"
          rules = [
            {
              # Scalar count — no per-target labels available; classic_conditions is fine.
              uid          = "efbh0063gz1tsb"
              title        = "Prometheus Target Down"
              condition    = "threshold"
              for          = "5m"
              noDataState  = "OK"
              execErrState = "OK"
              annotations = {
                summary     = "Prometheus scrape target is down"
                description = "One or more Prometheus scrape targets are unreachable."
              }
              labels = {
                severity = "warning"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 600
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "count(up == 0) OR vector(0)"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "threshold"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          params = [0]
                          type   = "gt"
                        }
                        operator = {
                          type = "and"
                        }
                        query = {
                          params = ["A"]
                        }
                        reducer = {
                          type = "last"
                        }
                        type = "query"
                      }
                    ]
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    refId      = "threshold"
                    type       = "classic_conditions"
                  }
                }
              ]
            }
          ]
        }
      ]
    })

    "kubernetes.yaml" = yamlencode({
      apiVersion = 1
      groups = [
        {
          orgId    = 1
          name     = "Kubernetes Pods"
          folder   = "Kubernetes"
          interval = "1m"
          rules = [
            {
              uid       = "pod-crashloopbackoff"
              title     = "PodCrashLoopBackOff"
              condition = "C"
              for       = "5m"
              annotations = {
                summary     = "Pod {{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} is in CrashLoopBackOff"
                description = "Container {{ $labels.container }} in pod {{ $labels.namespace }}/{{ $labels.pod }} has been in CrashLoopBackOff for more than 5 minutes."
              }
              labels = {
                severity = "warning"
              }
              data = [
                {
                  refId         = "A"
                  datasourceUid = "prometheus"
                  relativeTimeRange = {
                    from = 600
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "prometheus"
                      uid  = "prometheus"
                    }
                    expr          = "kube_pod_container_status_waiting_reason{reason=\"CrashLoopBackOff\"} == 1"
                    instant       = true
                    intervalMs    = 1000
                    maxDataPoints = 43200
                    refId         = "A"
                  }
                },
                {
                  refId         = "B"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    expression = "A"
                    reducer    = "last"
                    refId      = "B"
                    type       = "reduce"
                    settings = {
                      mode = "dropNN"
                    }
                  }
                },
                {
                  refId         = "C"
                  datasourceUid = "__expr__"
                  relativeTimeRange = {
                    from = 0
                    to   = 0
                  }
                  model = {
                    datasource = {
                      type = "__expr__"
                      uid  = "__expr__"
                    }
                    conditions = [
                      {
                        evaluator = {
                          params = [0]
                          type   = "gt"
                        }
                      }
                    ]
                    expression = "B"
                    refId      = "C"
                    type       = "threshold"
                  }
                }
              ]
            }
          ]
        }
      ]
    })
  }
}

# PVC for Grafana data
resource "kubernetes_persistent_volume_claim" "grafana_data" {
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

# Grafana Deployment with OAuth
resource "kubernetes_deployment" "grafana" {
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
      }

      spec {
        container {
          name  = local.app_name
          image = "${var.image_registry}/${var.image_name}:${var.image_tag}"

          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }

          env {
            name  = "GF_INSTALL_PLUGINS"
            value = ""
          }

          # OAuth configuration
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ENABLED"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_NAME"
            value = "Keycloak"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP"
            value = "true"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
            value = var.keycloak_client_id
          }
          env {
            name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "OAUTH_CLIENT_SECRET"
              }
            }
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_SCOPES"
            value = "openid email profile"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_NAME"
            value = "email"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH"
            value = "email"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_AUTH_URL"
            value = "${var.keycloak_url}/realms/${var.keycloak_realm}/protocol/openid-connect/auth"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_TOKEN_URL"
            value = "${var.keycloak_url}/realms/${var.keycloak_realm}/protocol/openid-connect/token"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_API_URL"
            value = "${var.keycloak_url}/realms/${var.keycloak_realm}/protocol/openid-connect/userinfo"
          }
          env {
            name  = "GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE"
            value = "false"
          }

          # Server configuration
          env {
            name  = "GF_SERVER_ROOT_URL"
            value = "https://${var.ingress_hostname}"
          }

          # Admin password from Vault
          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "${local.app_name}-secrets"
                key  = "GF_SECURITY_ADMIN_PASSWORD"
              }
            }
          }

          # Database path
          env {
            name  = "GF_PATHS_DATA"
            value = "/var/lib/grafana"
          }
          env {
            name  = "GF_PATHS_LOGS"
            value = "/var/log/grafana"
          }
          env {
            name  = "GF_PATHS_PLUGINS"
            value = "/var/lib/grafana/plugins"
          }
          env {
            name  = "GF_PATHS_PROVISIONING"
            value = "/etc/grafana/provisioning"
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
            name       = "data"
            mount_path = "/var/lib/grafana"
          }

          volume_mount {
            name       = "datasources"
            mount_path = "/etc/grafana/provisioning/datasources"
            read_only  = true
          }

          volume_mount {
            name       = "dashboard-config"
            mount_path = "/etc/grafana/provisioning/dashboards"
            read_only  = true
          }

          volume_mount {
            name       = "alerting"
            mount_path = "/etc/grafana/provisioning/alerting"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.grafana_data.metadata[0].name
          }
        }

        volume {
          name = "datasources"
          config_map {
            name = kubernetes_config_map.datasources.metadata[0].name
          }
        }

        volume {
          name = "dashboard-config"
          config_map {
            name = kubernetes_config_map.dashboards.metadata[0].name
          }
        }

        volume {
          name = "alerting"
          config_map {
            name = kubernetes_config_map.alerting.metadata[0].name
          }
        }
      }
    }
  }
}

# Grafana Service
resource "kubernetes_service" "grafana" {
  metadata {
    name      = local.app_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name"     = local.app_name
      "app.kubernetes.io/instance" = local.app_name
    }

    port {
      name        = "http"
      port        = 3000
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# Grafana IngressRoute
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
              name = kubernetes_service.grafana.metadata[0].name
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