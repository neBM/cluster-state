# Kubernetes Module Contract

**Date**: 2026-01-21

This document defines the standard pattern for Terraform modules deploying Kubernetes services.

## Module Structure

```
modules-k8s/<service>/
├── main.tf           # Primary resources (Deployment/StatefulSet, Service, Ingress)
├── variables.tf      # Input variables
├── outputs.tf        # Output values
├── secrets.tf        # ExternalSecret definitions (if needed)
├── vpa.tf            # VerticalPodAutoscaler (if needed)
└── versions.tf       # Provider requirements
```

## Standard Variables

All K8s modules MUST accept these variables:

```hcl
variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
}
```

## Standard Outputs

All K8s modules SHOULD provide these outputs:

```hcl
output "service_name" {
  description = "Name of the Kubernetes service"
  value       = kubernetes_service.main.metadata[0].name
}

output "ingress_hostname" {
  description = "Hostname configured in ingress (if any)"
  value       = try(kubernetes_ingress_v1.main[0].spec[0].rules[0].host, null)
}
```

## Provider Requirements

```hcl
# versions.tf
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
```

## Naming Conventions

| Resource Type | Naming Pattern |
|---------------|----------------|
| Namespace | `default` (PoC) or `<service>` (future) |
| Deployment/StatefulSet | `<service>` |
| Service | `<service>` |
| Ingress | `<service>` |
| VPA | `<service>-vpa` |
| ExternalSecret | `<service>-secrets` |
| ConfigMap | `<service>-config` |
| PVC | `<service>-data` |

## Labels

All resources MUST have these labels:

```yaml
labels:
  app: <service>
  managed-by: terraform
  environment: poc
```

## Resource Requests/Limits Pattern

Start with conservative requests, allow VPA to optimize:

```hcl
resources {
  requests = {
    cpu    = "100m"
    memory = "128Mi"
  }
  limits = {
    cpu    = "500m"
    memory = "512Mi"
  }
}
```

## Stateless Service Pattern (Deployment)

See `modules-k8s/whoami/main.tf` for reference implementation.

## Stateful Service Pattern (StatefulSet)

See `modules-k8s/overseerr/main.tf` for reference implementation with:
- Litestream sidecar for SQLite backup
- PVC for persistent data
- ExternalSecret for Vault integration

## Ingress Pattern

```hcl
resource "kubernetes_ingress_v1" "main" {
  metadata {
    name      = var.service_name
    namespace = var.namespace
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"
    
    tls {
      hosts       = ["${var.service_name}.brmartin.co.uk"]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = "${var.service_name}.brmartin.co.uk"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.main.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
```

## VPA Pattern

```hcl
resource "kubectl_manifest" "vpa" {
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "${var.service_name}-vpa"
      namespace = var.namespace
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"  # or "StatefulSet"
        name       = var.service_name
      }
      updatePolicy = {
        updateMode = var.vpa_mode  # "Auto" or "Off"
      }
      resourcePolicy = {
        containerPolicies = [{
          containerName = var.service_name
          minAllowed = {
            cpu    = "50m"
            memory = "64Mi"
          }
          maxAllowed = {
            cpu    = "2"
            memory = "2Gi"
          }
        }]
      }
    }
  })
}
```

## ExternalSecret Pattern

```hcl
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${var.service_name}-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "${var.service_name}-secrets"
        creationPolicy = "Owner"
      }
      data = [
        for key in var.secret_keys : {
          secretKey = key
          remoteRef = {
            key      = "nomad/data/default/${var.service_name}"
            property = key
          }
        }
      ]
    }
  })
}
```
