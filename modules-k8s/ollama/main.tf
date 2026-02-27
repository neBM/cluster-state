locals {
  app_name = "ollama"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

# Deployment with GPU support
resource "kubernetes_deployment" "ollama" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    # GPU resources can't be shared - must terminate old pod before starting new
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Use nvidia runtime class for GPU support
        runtime_class_name = "nvidia"

        container {
          name  = "ollama"
          image = "ollama/ollama:${var.image_tag}"

          port {
            container_port = 11434
            name           = "api"
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
            name       = "data"
            mount_path = "/root/.ollama"
          }

          resources {
            requests = {
              cpu              = "100m"
              memory           = "2000Mi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              cpu              = "4"
              memory           = "8Gi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 11434
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 11434
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Use emptyDir for models - they're downloaded on demand
        # Can switch to hostPath for persistence if needed
        volume {
          name = "data"
          empty_dir {
            size_limit = "20Gi"
          }
        }

        # Must run on Hestia (GPU node)
        node_selector = {
          "kubernetes.io/hostname" = "hestia"
        }

        # Tolerate GPU taint if present
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      }
    }
  }
}

resource "kubernetes_service" "ollama" {
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
      port        = 11434
      target_port = 11434
      protocol    = "TCP"
      name        = "api"
      node_port   = 31434
    }

    type = "NodePort"
  }
}
