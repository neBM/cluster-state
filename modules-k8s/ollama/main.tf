locals {
  app_name = "ollama"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"
  }
}

resource "kubectl_manifest" "ollama" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = local.app_name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      replicas = 1
      strategy = { type = "Recreate" }
      selector = { matchLabels = { app = local.app_name } }
      template = {
        metadata = { labels = local.labels }
        spec = {
          resourceClaims = [{
            name              = "gpu"
            resourceClaimName = "hestia-gpu"
          }]
          containers = [{
            name  = "ollama"
            image = "ollama/ollama:${var.image_tag}"
            ports = [{ containerPort = 11434, name = "api" }]
            resources = {
              requests = {
                cpu    = "100m"
                memory = "200Mi"
              }
              limits = {
                cpu    = "4"
                memory = "8Gi"
              }
              claims = [{ name = "gpu" }]
            }
            volumeMounts = [{
              name      = "data"
              mountPath = "/root/.ollama"
            }]
            livenessProbe = {
              httpGet             = { path = "/", port = 11434 }
              initialDelaySeconds = 30
              periodSeconds       = 30
              timeoutSeconds      = 5
            }
            readinessProbe = {
              httpGet             = { path = "/", port = 11434 }
              initialDelaySeconds = 10
              periodSeconds       = 10
              timeoutSeconds      = 5
            }
          }]
          volumes = [{
            name     = "data"
            emptyDir = { sizeLimit = "20Gi" }
          }]
        }
      }
    }
  })

  depends_on = []
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
