locals {
  app_name = "clickhouse"
  labels = {
    app        = local.app_name
    managed-by = "terraform"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "clickhouse_data" {
  metadata {
    name      = "clickhouse-data-sw"
    namespace = var.namespace
    labels    = local.labels
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

resource "kubernetes_config_map_v1" "clickhouse_config" {
  metadata {
    name      = "clickhouse-config"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "cluster.xml" = <<-XML
      <clickhouse>
        <keeper_server>
          <tcp_port>9181</tcp_port>
          <server_id>1</server_id>
          <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
          <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
          <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
          </coordination_settings>
          <raft_configuration>
            <server>
              <id>1</id>
              <hostname>localhost</hostname>
              <port>9444</port>
            </server>
          </raft_configuration>
        </keeper_server>
        <zookeeper>
          <node>
            <host>localhost</host>
            <port>9181</port>
          </node>
        </zookeeper>
        <remote_servers>
          <default>
            <shard>
              <replica>
                <host>localhost</host>
                <port>9000</port>
              </replica>
            </shard>
          </default>
        </remote_servers>
        <macros>
          <shard>1</shard>
          <replica>clickhouse-1</replica>
        </macros>
      </clickhouse>
    XML
  }
}

resource "kubernetes_deployment_v1" "clickhouse" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = "clickhouse"
          image = "clickhouse/clickhouse-server:${var.image_tag}"

          port {
            container_port = 8123
            name           = "http"
          }

          port {
            container_port = 9000
            name           = "native"
          }

          env {
            name  = "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT"
            value = "1"
          }

          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "clickhouse-secrets"
                key  = "CLICKHOUSE_PASSWORD"
              }
            }
          }

          liveness_probe {
            http_get {
              path   = "/ping"
              port   = 8123
              scheme = "HTTP"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path   = "/ping"
              port   = 8123
              scheme = "HTTP"
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "clickhouse-data"
            mount_path = "/var/lib/clickhouse"
          }

          volume_mount {
            name       = "clickhouse-config"
            mount_path = "/etc/clickhouse-server/config.d"
            read_only  = true
          }
        }

        volume {
          name = "clickhouse-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.clickhouse_data.metadata[0].name
          }
        }

        volume {
          name = "clickhouse-config"
          config_map {
            name = kubernetes_config_map_v1.clickhouse_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.clickhouse_data]
}

resource "kubernetes_service_v1" "clickhouse" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = {
      app = local.app_name
    }

    port {
      name       = "http"
      port       = 8123
      target_port = 8123
      protocol   = "TCP"
    }

    port {
      name       = "native"
      port       = 9000
      target_port = 9000
      protocol   = "TCP"
    }

    type = "ClusterIP"
  }
}
