# GitLab Runner - CI/CD job execution
#
# Two deployments: amd64 (Hestia) and arm64 (Heracles/Nyx)
# Requires privileged mode and Docker socket access
# Connects to GitLab at git.brmartin.co.uk
#
# Uses init container to generate config.toml from template + secrets

locals {
  labels = {
    app        = "gitlab-runner"
    managed-by = "terraform"
  }

  config_template = <<-EOF
concurrent = 1
check_interval = 30
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "RUNNER_NAME_PLACEHOLDER"
  url = "https://git.brmartin.co.uk"
  token = "RUNNER_TOKEN_PLACEHOLDER"
  executor = "docker"
  
  [runners.docker]
    tls_verify = false
    image = "alpine:latest"
    privileged = true
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/cache", "/var/run/docker.sock:/var/run/docker.sock"]
    shm_size = 0
    network_mtu = 0
EOF
}

# =============================================================================
# ConfigMap for config template
# =============================================================================

resource "kubernetes_config_map" "config_template" {
  metadata {
    name      = "gitlab-runner-config-template"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "config.toml.template" = local.config_template
  }
}

# =============================================================================
# AMD64 Runner (runs on Hestia)
# =============================================================================

resource "kubernetes_deployment" "runner_amd64" {
  metadata {
    name      = "gitlab-runner-amd64"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "amd64" })
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = merge(local.labels, { arch = "amd64" })
    }

    template {
      metadata {
        labels = merge(local.labels, { arch = "amd64" })
      }

      spec {
        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        # Init container to generate config from template + secret
        init_container {
          name    = "config-generator"
          image   = "busybox:1.36"
          command = ["/bin/sh", "-c"]
          args = [
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-amd64/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" /template/config.toml.template > /config/config.toml"
          ]

          env {
            name = "RUNNER_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-runner-secrets"
                key  = "runner_token_amd64"
              }
            }
          }

          volume_mount {
            name       = "config-template"
            mount_path = "/template"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }

        container {
          name  = "gitlab-runner"
          image = var.image
          args  = ["run", "--config", "/config/config.toml"]

          security_context {
            privileged = true
          }

          volume_mount {
            name       = "docker-sock"
            mount_path = "/var/run/docker.sock"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "docker-sock"
          host_path {
            path = "/var/run/docker.sock"
            type = "Socket"
          }
        }

        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.config_template.metadata[0].name
          }
        }

        volume {
          name = "config"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

# =============================================================================
# ARM64 Runner (runs on Heracles/Nyx)
# =============================================================================

resource "kubernetes_deployment" "runner_arm64" {
  metadata {
    name      = "gitlab-runner-arm64"
    namespace = var.namespace
    labels    = merge(local.labels, { arch = "arm64" })
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = merge(local.labels, { arch = "arm64" })
    }

    template {
      metadata {
        labels = merge(local.labels, { arch = "arm64" })
      }

      spec {
        node_selector = {
          "kubernetes.io/arch" = "arm64"
        }

        # Init container to generate config from template + secret
        init_container {
          name    = "config-generator"
          image   = "busybox:1.36"
          command = ["/bin/sh", "-c"]
          args = [
            "sed -e \"s/RUNNER_NAME_PLACEHOLDER/k8s-arm64/\" -e \"s/RUNNER_TOKEN_PLACEHOLDER/$RUNNER_TOKEN/\" /template/config.toml.template > /config/config.toml"
          ]

          env {
            name = "RUNNER_TOKEN"
            value_from {
              secret_key_ref {
                name = "gitlab-runner-secrets"
                key  = "runner_token_arm64"
              }
            }
          }

          volume_mount {
            name       = "config-template"
            mount_path = "/template"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }

        container {
          name  = "gitlab-runner"
          image = var.image
          args  = ["run", "--config", "/config/config.toml"]

          security_context {
            privileged = true
          }

          volume_mount {
            name       = "docker-sock"
            mount_path = "/var/run/docker.sock"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "docker-sock"
          host_path {
            path = "/var/run/docker.sock"
            type = "Socket"
          }
        }

        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.config_template.metadata[0].name
          }
        }

        volume {
          name = "config"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

# =============================================================================
# External Secret for runner tokens
# =============================================================================

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "gitlab-runner-secrets"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "gitlab-runner-secrets"
      }
      data = [
        {
          secretKey = "runner_token_amd64"
          remoteRef = {
            key      = "nomad/default/gitlab-runner"
            property = "runner_token_amd64"
          }
        },
        {
          secretKey = "runner_token_arm64"
          remoteRef = {
            key      = "nomad/default/gitlab-runner"
            property = "runner_token_arm64"
          }
        }
      ]
    }
  })
}
