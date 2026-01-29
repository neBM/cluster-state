# Renovate - Automated dependency updates for GitLab repositories
#
# Runs hourly, autodiscovers all GitLab repositories
# Requires RENOVATE_TOKEN and GITHUB_COM_TOKEN from Vault

locals {
  labels = {
    app        = "renovate"
    managed-by = "terraform"
  }
}

# =============================================================================
# CronJob
# =============================================================================

resource "kubernetes_cron_job_v1" "renovate" {
  metadata {
    name      = "renovate"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = "0 * * * *" # Every hour
    concurrency_policy            = "Forbid"    # Don't allow overlapping runs
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = local.labels
      }

      spec {
        backoff_limit = 2

        template {
          metadata {
            labels = local.labels
          }

          spec {
            restart_policy = "OnFailure"

            container {
              name  = "renovate"
              image = "${var.image}:${var.image_tag}"

              env {
                name  = "RENOVATE_PLATFORM"
                value = "gitlab"
              }

              env {
                name  = "RENOVATE_ENDPOINT"
                value = "http://gitlab-workhorse.default.svc.cluster.local:8181/api/v4"
              }

              env {
                name  = "RENOVATE_AUTODISCOVER"
                value = "true"
              }

              env {
                name  = "RENOVATE_GIT_AUTHOR"
                value = "Renovate Bot <renovate@brmartin.co.uk>"
              }

              env {
                name  = "LOG_FORMAT"
                value = "json"
              }

              env {
                name  = "RENOVATE_DEPENDENCY_DASHBOARD"
                value = "true"
              }

              env {
                name = "RENOVATE_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "renovate-secrets"
                    key  = "RENOVATE_TOKEN"
                  }
                }
              }

              env {
                name = "GITHUB_COM_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "renovate-secrets"
                    key  = "GITHUB_COM_TOKEN"
                  }
                }
              }

              resources {
                requests = {
                  cpu    = "1000m"  # goldilocks: 1311m
                  memory = "512Mi"
                }
                limits = {
                  cpu    = "2000m"
                  memory = "1Gi"
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.external_secret]
}

# =============================================================================
# External Secret
# =============================================================================

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "renovate-secrets"
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
        name = "renovate-secrets"
      }
      data = [
        {
          secretKey = "RENOVATE_TOKEN"
          remoteRef = {
            key      = "nomad/default/renovate"
            property = "RENOVATE_TOKEN"
          }
        },
        {
          secretKey = "GITHUB_COM_TOKEN"
          remoteRef = {
            key      = "nomad/default/renovate"
            property = "GITHUB_COM_TOKEN"
          }
        }
      ]
    }
  })
}
