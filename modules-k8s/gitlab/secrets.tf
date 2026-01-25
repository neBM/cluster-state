# GitLab Secrets for Multi-Container Architecture (CNG)
#
# IMPORTANT: Secrets are NOT managed in Terraform to avoid committing sensitive data to git.
# 
# Secrets must be created manually using kubectl before applying this module.
# See the migration runbook in specs/008-gitlab-multi-container/quickstart.md for instructions.
#
# Required secrets:
# 1. gitlab-secrets (db_password) - Created by External Secrets Operator from Vault
# 2. gitlab-rails-secret (secrets.yml) - Extracted from Omnibus, applied via kubectl
# 3. gitlab-workhorse (secret) - Extracted from Omnibus, applied via kubectl
# 4. gitlab-shell (.gitlab_shell_secret) - Extracted from Omnibus, applied via kubectl
# 5. gitlab-gitaly (token) - Generated, applied via kubectl
# 6. gitlab-registry-auth (gitlab-registry.key, gitlab-registry.crt) - Extracted from Omnibus, applied via kubectl

# =============================================================================
# Database Password (from Vault via External Secrets Operator)
# =============================================================================

# This is the only secret managed via Terraform - it pulls from Vault
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "gitlab-secrets"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-backend"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "gitlab-secrets"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "db_password"
          remoteRef = {
            key      = "nomad/default/gitlab"
            property = "db_password"
          }
        }
      ]
    }
  })
}

# =============================================================================
# Manual Secret Creation Instructions
# =============================================================================
#
# Run these commands on the cluster BEFORE applying Terraform:
#
# 1. Extract secrets from running Omnibus container:
#    kubectl exec -it $(kubectl get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}') -- \
#      cat /etc/gitlab/gitlab-secrets.json > /tmp/gitlab-secrets.json
#
# 2. Create gitlab-rails-secret (see quickstart.md for full secrets.yml content):
#    kubectl create secret generic gitlab-rails-secret \
#      --from-file=secrets.yml=/tmp/secrets.yml
#
# 3. Create gitlab-workhorse secret:
#    kubectl create secret generic gitlab-workhorse \
#      --from-literal=secret="$(jq -r '.gitlab_workhorse.secret_token' /tmp/gitlab-secrets.json)"
#
# 4. Create gitlab-shell secret:
#    kubectl create secret generic gitlab-shell \
#      --from-literal=.gitlab_shell_secret="$(jq -r '.gitlab_shell.secret_token' /tmp/gitlab-secrets.json)"
#
# 5. Create gitlab-gitaly secret (generate new token):
#    kubectl create secret generic gitlab-gitaly \
#      --from-literal=token="$(openssl rand -hex 32)"
#
# 6. Create gitlab-registry-auth secret:
#    jq -r '.registry.internal_key' /tmp/gitlab-secrets.json > /tmp/gitlab-registry.key
#    jq -r '.registry.internal_certificate' /tmp/gitlab-secrets.json > /tmp/gitlab-registry.crt
#    kubectl create secret generic gitlab-registry-auth \
#      --from-file=gitlab-registry.key=/tmp/gitlab-registry.key \
#      --from-file=gitlab-registry.crt=/tmp/gitlab-registry.crt
#
# 7. Clean up temporary files:
#    rm -f /tmp/gitlab-secrets.json /tmp/secrets.yml /tmp/gitlab-registry.key /tmp/gitlab-registry.crt
