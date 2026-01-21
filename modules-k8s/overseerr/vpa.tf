# VPA for automatic resource recommendations and scaling
resource "kubectl_manifest" "vpa" {
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "${local.app_name}-vpa"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "StatefulSet"
        name       = local.app_name
      }
      updatePolicy = {
        updateMode = var.vpa_mode
      }
      resourcePolicy = {
        containerPolicies = [
          {
            containerName = local.app_name
            minAllowed = {
              cpu    = "50m"
              memory = "128Mi"
            }
            maxAllowed = {
              cpu    = "1"
              memory = "1Gi"
            }
          },
          {
            containerName = "litestream"
            minAllowed = {
              cpu    = "10m"
              memory = "32Mi"
            }
            maxAllowed = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        ]
      }
    }
  })

  depends_on = [kubernetes_stateful_set.overseerr]
}
