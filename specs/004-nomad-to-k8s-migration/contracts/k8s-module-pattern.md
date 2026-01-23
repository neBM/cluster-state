# Contract: Kubernetes Module Pattern

**Phase**: 1 - Design  
**Date**: 2026-01-22

## Module Structure

Each service gets a Terraform module at `modules-k8s/<service>/`:

```
modules-k8s/<service>/
├── main.tf           # Deployment/StatefulSet, Service, Ingress
├── variables.tf      # Input variables
├── versions.tf       # Provider requirements
├── outputs.tf        # Exported values
├── secrets.tf        # ExternalSecret (if needed)
└── vpa.tf            # VerticalPodAutoscaler (optional)
```

---

## Standard Variables (variables.tf)

```hcl
variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "latest"
}

# For litestream services
variable "litestream_image_tag" {
  description = "Litestream image tag"
  type        = string
  default     = "0.3"
}

variable "minio_endpoint" {
  description = "MinIO S3 endpoint for litestream"
  type        = string
  default     = "http://minio-minio.service.consul:9000"
}

variable "litestream_bucket" {
  description = "MinIO bucket for litestream backups"
  type        = string
}
```

---

## Standard Outputs (outputs.tf)

```hcl
output "service_name" {
  description = "K8s Service name"
  value       = kubernetes_service.<service>.metadata[0].name
}

output "hostname" {
  description = "External hostname"
  value       = var.hostname
}

output "namespace" {
  description = "Deployed namespace"
  value       = var.namespace
}
```

---

## Standard versions.tf

```hcl
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

---

## Pattern A: Simple Deployment (Stateless)

For services without persistent state (searxng, nginx-sites):

```hcl
resource "kubernetes_deployment" "<service>" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = local.app_name }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = local.app_name
          image = "<image>:${var.image_tag}"
          port { container_port = <port> }
          
          volume_mount {
            name       = "config"
            mount_path = "/etc/<service>"
          }
          
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
          
          liveness_probe { ... }
          readiness_probe { ... }
        }
        
        volume {
          name = "config"
          host_path {
            path = "/storage/v/glusterfs_<service>_config"
            type = "Directory"
          }
        }
        
        # Multi-arch support
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/arch"
                  operator = "In"
                  values   = ["amd64", "arm64"]
                }
              }
            }
          }
        }
      }
    }
  }
}
```

---

## Pattern B: StatefulSet with Litestream

For SQLite services (vaultwarden, overseerr, open-webui):

```hcl
resource "kubernetes_config_map" "litestream" {
  metadata {
    name      = "${local.app_name}-litestream"
    namespace = var.namespace
  }

  data = {
    "litestream.yml" = yamlencode({
      dbs = [{
        path = "/data/db.sqlite3"
        replicas = [{
          type             = "s3"
          bucket           = var.litestream_bucket
          endpoint         = var.minio_endpoint
          force-path-style = true
        }]
      }]
    })
  }
}

resource "kubernetes_stateful_set" "<service>" {
  spec {
    template {
      spec {
        # Restore from backup on start
        init_container {
          name  = "litestream-restore"
          image = "litestream/litestream:${var.litestream_image_tag}"
          command = ["/bin/sh", "-c"]
          args = [<<-EOF
            if [ ! -f /data/db.sqlite3 ]; then
              litestream restore -config /etc/litestream.yml /data/db.sqlite3 || true
            fi
          EOF
          ]
          # volume mounts, env vars for S3 credentials
        }
        
        # Main application
        container {
          name = local.app_name
          # ...
        }
        
        # Continuous replication sidecar
        container {
          name  = "litestream"
          image = "litestream/litestream:${var.litestream_image_tag}"
          args  = ["replicate", "-config", "/etc/litestream.yml"]
          # volume mounts, env vars for S3 credentials
        }
        
        # Ephemeral storage for SQLite
        volume {
          name = "data"
          empty_dir { size_limit = "500Mi" }
        }
      }
    }
  }
}
```

---

## Pattern C: GlusterFS hostPath

For services with persistent data on GlusterFS:

```hcl
resource "kubernetes_stateful_set" "<service>" {
  spec {
    template {
      spec {
        container {
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        
        volume {
          name = "data"
          host_path {
            path = "/storage/v/glusterfs_<service>_data"
            type = "Directory"
          }
        }
      }
    }
  }
}
```

---

## Pattern D: GPU Workload

For GPU-accelerated services (ollama):

```hcl
resource "kubernetes_deployment" "ollama" {
  spec {
    template {
      spec {
        container {
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
        }
        
        node_selector = {
          "kubernetes.io/hostname" = "hestia"
        }
        
        # Or use tolerations for GPU nodes
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      }
    }
  }
}
```

---

## Pattern E: CronJob

For periodic jobs (renovate, restic-backup):

```hcl
resource "kubernetes_cron_job_v1" "<service>" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
  }

  spec {
    schedule = var.schedule  # e.g., "0 */4 * * *"
    
    job_template {
      spec {
        template {
          spec {
            container {
              name  = local.app_name
              image = "<image>:${var.image_tag}"
              # ...
            }
            restart_policy = "Never"
          }
        }
        backoff_limit = 3
      }
    }
  }
}
```

---

## Standard Service + Ingress

```hcl
resource "kubernetes_service" "<service>" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = { app = local.app_name }
    port {
      port        = 80
      target_port = <container_port>
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "<service>" {
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = [var.hostname]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.<service>.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }
}
```

---

## ExternalSecret Pattern

```hcl
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.app_name}-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "${local.app_name}-secrets"
      }
      data = [
        for key in var.secret_keys : {
          secretKey = key
          remoteRef = {
            key      = "default/${local.app_name}"
            property = key
          }
        }
      ]
    }
  })
}
```

---

## Labels Convention

```hcl
locals {
  app_name = "<service>"
  labels = {
    app         = local.app_name
    managed-by  = "terraform"
    environment = "prod"  # Changed from "poc"
  }
}
```

---

## Resource Limits Guidelines

| Service Type | CPU Request | CPU Limit | Memory Request | Memory Limit |
|--------------|-------------|-----------|----------------|--------------|
| Light (searxng) | 50m | 200m | 64Mi | 256Mi |
| Medium (vaultwarden) | 100m | 500m | 128Mi | 512Mi |
| Heavy (gitlab) | 500m | 2000m | 1Gi | 4Gi |
| GPU (ollama) | 500m | 2000m | 2Gi | 8Gi |

Match or slightly exceed Nomad resource allocations.
