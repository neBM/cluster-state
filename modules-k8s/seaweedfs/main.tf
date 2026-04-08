locals {
  app_name = "seaweedfs"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }

  master_peers = join(",", [
    for i in range(var.master_replicas) :
    "seaweedfs-master-${i}.seaweedfs-master.${var.namespace}.svc.cluster.local:9333"
  ])
}

# -----------------------------------------------------------------------------
# Master — Raft quorum (StatefulSet)
# -----------------------------------------------------------------------------

resource "kubernetes_service" "master_headless" {
  metadata {
    name      = "seaweedfs-master"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "master" })
  }

  spec {
    cluster_ip                  = "None"
    publish_not_ready_addresses = true
    selector                    = { app = local.app_name, component = "master" }

    port {
      name        = "http"
      port        = 9333
      target_port = 9333
      protocol    = "TCP"
    }

    port {
      name        = "grpc"
      port        = 19333
      target_port = 19333
      protocol    = "TCP"
    }
  }
}

# ClusterIP service for ingress (headless can't be used as IngressRoute backend)
resource "kubernetes_service" "master" {
  count = var.master_ingress_hostname != "" ? 1 : 0

  metadata {
    name      = "seaweedfs-master-ui"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "master" })
  }

  spec {
    selector = { app = local.app_name, component = "master" }

    port {
      name        = "http"
      port        = 9333
      target_port = 9333
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubectl_manifest" "master_ingressroute" {
  count = var.master_ingress_hostname != "" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "seaweedfs-master"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.master_ingress_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.master[0].metadata[0].name
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

resource "kubernetes_stateful_set" "master" {
  metadata {
    name      = "seaweedfs-master"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "master" })
  }

  spec {
    service_name          = kubernetes_service.master_headless.metadata[0].name
    replicas              = var.master_replicas
    pod_management_policy = "Parallel"

    selector {
      match_labels = { app = local.app_name, component = "master" }
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "master" })
      }

      spec {
        # All nodes are control-plane in this cluster
        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        # Spread masters across nodes
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = { app = local.app_name, component = "master" }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        container {
          name  = "master"
          image = "chrislusf/seaweedfs:${var.seaweedfs_image_tag}"

          args = [
            "master",
            "-mdir=/data",
            "-peers=${local.master_peers}",
            "-port=9333",
            "-port.grpc=19333",
            "-defaultReplication=${var.replication}",
            "-ip=$(POD_NAME).seaweedfs-master.${var.namespace}.svc.cluster.local",
          ]

          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          port {
            name           = "http"
            container_port = 9333
          }

          port {
            name           = "grpc"
            container_port = 19333
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            http_get {
              path = "/cluster/status"
              port = 9333
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/cluster/status"
              port = 9333
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "data"
          host_path {
            path = var.master_data_path
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}
