locals {
  prometheus_target_down_expr = trimspace(<<-EOT
    label_replace(
      (1 - up{job="kubernetes-nodes"}) > 0,
      "node",
      "$1",
      "instance",
      "(.*)"
    )
    or
    (
      label_replace(
        (1 - up{job="kubernetes-apiservers"}) > 0,
        "internal_ip",
        "$1",
        "instance",
        "(.*):.*"
      )
      * on(internal_ip) group_left(node) kube_node_info
    )
    or
    (
      label_replace(
        (1 - up{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter"}) > 0,
        "internal_ip",
        "$1",
        "instance",
        "(.*):.*"
      )
      * on(internal_ip) group_left(node) kube_node_info
    )
    or
    (
      (1 - up) > 0
      unless on(job, instance) (
        label_replace(
          (1 - up{job="kubernetes-nodes"}) > 0,
          "node",
          "$1",
          "instance",
          "(.*)"
        )
        or
        (
          label_replace(
            (1 - up{job="kubernetes-apiservers"}) > 0,
            "internal_ip",
            "$1",
            "instance",
            "(.*):.*"
          )
          * on(internal_ip) group_left(node) kube_node_info
        )
        or
        (
          label_replace(
            (1 - up{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter"}) > 0,
            "internal_ip",
            "$1",
            "instance",
            "(.*):.*"
          )
          * on(internal_ip) group_left(node) kube_node_info
        )
      )
    )
    or
    (
      label_replace(
        label_replace(
          label_replace(
            sum by(job) (0 * up{job="kubernetes-nodes"}),
            "job",
            "all-targets",
            "job",
            ".*"
          ),
          "instance",
          "all-targets",
          "job",
          ".*"
        ),
        "fallback",
        "true",
        "job",
        ".*"
      )
      unless on() (
        label_replace(
          (1 - up{job="kubernetes-nodes"}) > 0,
          "node",
          "$1",
          "instance",
          "(.*)"
        )
        or
        (
          label_replace(
            (1 - up{job="kubernetes-apiservers"}) > 0,
            "internal_ip",
            "$1",
            "instance",
            "(.*):.*"
          )
          * on(internal_ip) group_left(node) kube_node_info
        )
        or
        (
          label_replace(
            (1 - up{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter"}) > 0,
            "internal_ip",
            "$1",
            "instance",
            "(.*):.*"
          )
          * on(internal_ip) group_left(node) kube_node_info
        )
        or
        (
          (1 - up) > 0
          unless on(job, instance) (
            label_replace(
              (1 - up{job="kubernetes-nodes"}) > 0,
              "node",
              "$1",
              "instance",
              "(.*)"
            )
            or
            (
              label_replace(
                (1 - up{job="kubernetes-apiservers"}) > 0,
                "internal_ip",
                "$1",
                "instance",
                "(.*):.*"
              )
              * on(internal_ip) group_left(node) kube_node_info
            )
            or
            (
              label_replace(
                (1 - up{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter"}) > 0,
                "internal_ip",
                "$1",
                "instance",
                "(.*):.*"
              )
              * on(internal_ip) group_left(node) kube_node_info
            )
          )
        )
      )
    )
  EOT
  )

  # Keep the desired Grafana-managed alert rules in Terraform and reconcile
  # them through the provider's rule-group resource on Grafana 13.
  grafana_alert_rule_groups = {
    "node-health" = {
      rules = [
        {
          uid            = "node-down-api"
          title          = "Node Down"
          condition      = "C"
          for            = "0s"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "Node {{ $labels.node }} is down"
            description = "node-exporter on {{ $labels.node }} ({{ $labels.instance }}) has had no successful scrapes for 2 minutes."
          }
          labels = {
            severity = "critical"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = "(label_replace(max_over_time(up{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\"}[2m]), \"internal_ip\", \"$1\", \"instance\", \"(.*):.*\") * on(internal_ip) group_left(node) kube_node_info) < 1"
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
        {
          uid            = "high-memory-usage-api"
          title          = "High Memory Usage"
          condition      = "C"
          for            = "5m"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "High memory usage on {{ $labels.node }}"
            description = "Memory usage on {{ $labels.node }} ({{ $labels.instance }}) has exceeded 90% for more than 5 minutes."
          }
          labels = {
            severity = "warning"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = "label_replace((1 - (node_memory_MemAvailable_bytes{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\"} / node_memory_MemTotal_bytes{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\"})) * 100, \"internal_ip\", \"$1\", \"instance\", \"(.*):.*\") * on(internal_ip) group_left(node) kube_node_info"
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
        {
          uid            = "high-cpu-usage-api"
          title          = "High CPU Usage"
          condition      = "C"
          for            = "10m"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "High CPU usage on {{ $labels.node }}"
            description = "CPU usage on {{ $labels.node }} ({{ $labels.instance }}) has exceeded 85% for more than 10 minutes."
          }
          labels = {
            severity = "warning"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = "label_replace(100 - (avg by(instance) (rate(node_cpu_seconds_total{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\",mode=\"idle\"}[5m])) * 100), \"internal_ip\", \"$1\", \"instance\", \"(.*):.*\") * on(internal_ip) group_left(node) kube_node_info"
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
        {
          uid            = "disk-space-low-api"
          title          = "Disk Space Low"
          condition      = "C"
          for            = "5m"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "Low disk space on {{ $labels.node }}"
            description = "Root filesystem on {{ $labels.node }} ({{ $labels.instance }}) has less than 15% free space."
          }
          labels = {
            severity = "critical"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = "label_replace((node_filesystem_avail_bytes{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\",mountpoint=\"/\",fstype!=\"tmpfs\"} / node_filesystem_size_bytes{job=\"kubernetes-service-endpoints\",app_kubernetes_io_name=\"node-exporter\",mountpoint=\"/\",fstype!=\"tmpfs\"}) * 100, \"internal_ip\", \"$1\", \"instance\", \"(.*):.*\") * on(internal_ip) group_left(node) kube_node_info"
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
      ]
    }
    "pod-health" = {
      rules = [
        {
          uid            = "pod-crashloopbackoff-api"
          title          = "Pod CrashLoopBackOff"
          condition      = "C"
          for            = "5m"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "Pod {{ $values.A.Labels.namespace }}/{{ $values.A.Labels.pod }} container {{ $values.A.Labels.container }} is in CrashLoopBackOff"
            description = "Container {{ $values.A.Labels.container }} in pod {{ $values.A.Labels.namespace }}/{{ $values.A.Labels.pod }} has been in CrashLoopBackOff for more than 5 minutes."
          }
          labels = {
            severity = "warning"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
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
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
        {
          uid            = "pod-restarting-frequently-api"
          title          = "Pod Restarting Frequently"
          condition      = "C"
          for            = "15m"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "Pod {{ $values.A.Labels.namespace }}/{{ $values.A.Labels.pod }} container {{ $values.A.Labels.container }} is restarting frequently"
            description = "Container {{ $values.A.Labels.container }} in pod {{ $values.A.Labels.namespace }}/{{ $values.A.Labels.pod }} has restarted more than 3 times in 15 minutes."
          }
          labels = {
            severity = "warning"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
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
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
      ]
    }
    "prometheus-health" = {
      rules = [
        {
          uid            = "prometheus-target-down-api"
          title          = "Prometheus Target Down"
          condition      = "C"
          for            = "5m"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "{{ if $values.A.Labels.fallback }}All Prometheus scrape targets are healthy{{ else }}Prometheus scrape target {{ $values.A.Labels.job }}/{{ if $values.A.Labels.node }}{{ $values.A.Labels.node }}{{ else if $values.A.Labels.kubernetes_io_hostname }}{{ $values.A.Labels.kubernetes_io_hostname }}{{ else }}{{ $values.A.Labels.instance }}{{ end }} is down{{ end }}"
            description = "{{ if $values.A.Labels.fallback }}No Prometheus scrape targets have been unreachable for more than 5 minutes.{{ else }}Scrape target {{ $values.A.Labels.job }}/{{ if $values.A.Labels.node }}{{ $values.A.Labels.node }}{{ else if $values.A.Labels.kubernetes_io_hostname }}{{ $values.A.Labels.kubernetes_io_hostname }}{{ else }}{{ $values.A.Labels.instance }}{{ end }} has been unreachable for more than 5 minutes.{{ end }}"
          }
          labels = {
            severity = "warning"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = local.prometheus_target_down_expr
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                  }
                ]
                datasource = {
                  type = "__expr__"
                  uid  = "__expr__"
                }
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
      ]
    }
    "etcd-health" = {
      rules = [
        {
          uid            = "etcd-request-errors-api"
          title          = "etcd Request Errors"
          condition      = "C"
          for            = "0s"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "etcd request errors on {{ if $labels.kubernetes_io_hostname }}{{ $labels.kubernetes_io_hostname }}{{ else if $labels.node }}{{ $labels.node }}{{ else }}{{ $labels.instance }}{{ end }}"
            description = "etcd has reported {{ $values.A }} request error(s) in the last 15 minutes on {{ if $labels.kubernetes_io_hostname }}{{ $labels.kubernetes_io_hostname }}{{ else if $labels.node }}{{ $labels.node }}{{ else }}{{ $labels.instance }}{{ end }}. Check k3s and embedded etcd logs on that node for failed storage requests."
          }
          labels = {
            severity = "warning"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = "sum by(instance, kubernetes_io_hostname) (increase(etcd_request_errors_total{job=\"kubernetes-nodes\"}[15m]))"
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
        {
          uid            = "storage-consistency-check-failure-api"
          title          = "Storage Consistency Check Failure"
          condition      = "C"
          for            = "0s"
          no_data_state  = "OK"
          exec_err_state = "OK"
          annotations = {
            summary     = "Storage consistency checks failed on {{ if $labels.kubernetes_io_hostname }}{{ $labels.kubernetes_io_hostname }}{{ else if $labels.node }}{{ $labels.node }}{{ else }}{{ $labels.instance }}{{ end }}"
            description = "The apiserver on {{ if $labels.kubernetes_io_hostname }}{{ $labels.kubernetes_io_hostname }}{{ else if $labels.node }}{{ $labels.node }}{{ else }}{{ $labels.instance }}{{ end }} has reported {{ $values.A }} non-success storage consistency check(s) in the last 15 minutes. This indicates an apiserver/etcd consistency problem and should be treated as critical."
          }
          labels = {
            severity = "critical"
          }
          data = [
            {
              ref_id         = "A"
              datasource_uid = "prometheus"
              relative_time_range = {
                from = 600
                to   = 0
              }
              model = {
                datasource = {
                  type = "prometheus"
                  uid  = "prometheus"
                }
                expr          = "sum by(instance, kubernetes_io_hostname) (increase(apiserver_storage_consistency_checks_total{job=\"kubernetes-nodes\",status!=\"success\"}[15m])) or sum by(instance, kubernetes_io_hostname) (0 * up{job=\"kubernetes-nodes\"})"
                instant       = true
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "A"
              }
            },
            {
              ref_id         = "C"
              datasource_uid = "__expr__"
              relative_time_range = {
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
                expression    = "A"
                intervalMs    = 1000
                maxDataPoints = 43200
                refId         = "C"
                type          = "threshold"
              }
            },
          ]
        },
      ]
    }
  }

  grafana_alert_rule_groups_provider = {
    for group_name, group in local.grafana_alert_rule_groups : group_name => {
      interval_seconds = 60
      rules = [
        for rule in group.rules : merge(rule, {
          data = [
            for query in rule.data : merge(query, {
              datasource_uid = query.datasource_uid == "__expr__" ? "-100" : query.datasource_uid
              model = try(query.model.datasource.uid, null) == "__expr__" ? merge(query.model, {
                datasource = merge(query.model.datasource, {
                  uid = "-100"
                })
              }) : query.model
            })
          ]
        })
      ]
    }
  }
}

resource "grafana_folder" "infrastructure_alerts" {
  depends_on = [
    kubectl_manifest.ingressroute,
    kubernetes_deployment_v1.grafana,
  ]

  uid   = "afbgzpfvsne9se"
  title = "Infrastructure Alerts"

  prevent_destroy_if_not_empty = true
}

resource "grafana_rule_group" "infrastructure_alerts" {
  for_each = local.grafana_alert_rule_groups_provider

  depends_on = [grafana_folder.infrastructure_alerts]

  folder_uid       = grafana_folder.infrastructure_alerts.uid
  interval_seconds = each.value.interval_seconds
  name             = each.key

  dynamic "rule" {
    for_each = each.value.rules

    content {
      uid            = rule.value.uid
      name           = rule.value.title
      condition      = rule.value.condition
      for            = rule.value.for
      no_data_state  = rule.value.no_data_state
      exec_err_state = rule.value.exec_err_state
      annotations    = rule.value.annotations
      labels         = rule.value.labels
      is_paused      = false

      dynamic "data" {
        for_each = rule.value.data

        content {
          ref_id         = data.value.ref_id
          query_type     = try(data.value.query_type, "")
          datasource_uid = data.value.datasource_uid
          model          = jsonencode(data.value.model)

          relative_time_range {
            from = data.value.relative_time_range.from
            to   = data.value.relative_time_range.to
          }
        }
      }
    }
  }
}
