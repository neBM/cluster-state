# -----------------------------------------------------------------------------
# Filer — StatefulSet with embedded leveldb
# -----------------------------------------------------------------------------

resource "kubernetes_service" "filer" {
  count = var.filer_ingress_hostname != "" ? 1 : 0

  metadata {
    name      = "seaweedfs-filer-ui"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "filer" })
  }

  spec {
    selector = { app = local.app_name, component = "filer" }

    port {
      name        = "http"
      port        = 8888
      target_port = 8888
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubectl_manifest" "filer_ingressroute" {
  count = var.filer_ingress_hostname != "" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "seaweedfs-filer"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.filer_ingress_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service.filer[0].metadata[0].name
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

resource "kubernetes_service" "filer_headless" {
  metadata {
    name      = "seaweedfs-filer"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "filer" })
  }

  spec {
    cluster_ip = "None"
    selector   = { app = local.app_name, component = "filer" }

    port {
      name        = "http"
      port        = 8888
      target_port = 8888
      protocol    = "TCP"
    }

    port {
      name        = "grpc"
      port        = 18888
      target_port = 18888
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_stateful_set" "filer" {
  metadata {
    name      = "seaweedfs-filer"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "filer" })
  }

  spec {
    service_name = kubernetes_service.filer_headless.metadata[0].name
    replicas     = var.filer_replicas

    selector {
      match_labels = { app = local.app_name, component = "filer" }
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "filer" })
      }

      spec {
        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "filer"
          image = "chrislusf/seaweedfs:${var.seaweedfs_image_tag}"

          args = [
            "filer",
            "-master=seaweedfs-master:9333",
            "-port=8888",
            "-port.grpc=18888",
            "-defaultReplicaPlacement=${var.replication}",
            "-ip=$(POD_NAME).seaweedfs-filer.${var.namespace}.svc.cluster.local",
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
            container_port = 8888
          }

          port {
            name           = "grpc"
            container_port = 18888
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8888
            }
            initial_delay_seconds = 15
            period_seconds        = 15
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8888
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "data"
          host_path {
            path = var.filer_data_path
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}
