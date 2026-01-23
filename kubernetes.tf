# Kubernetes Configuration for PoC Migration
#
# This file configures the Kubernetes provider and K8s-based modules.
# The K8s cluster must be installed separately (see specs/003-nomad-to-kubernetes/quickstart.md)
#
# To enable K8s modules, set the environment variable:
#   export TF_VAR_enable_k8s=true

variable "enable_k8s" {
  description = "Enable Kubernetes modules (requires K3s cluster to be installed)"
  type        = bool
  default     = false
}

variable "k8s_config_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/k3s-config"
}

variable "k8s_context" {
  description = "Kubernetes context to use"
  type        = string
  default     = "default"
}

# Kubernetes provider - only active when K8s is enabled
provider "kubernetes" {
  config_path    = var.enable_k8s ? pathexpand(var.k8s_config_path) : null
  config_context = var.enable_k8s ? var.k8s_context : null
}

# kubectl provider for CRDs (VPA, ExternalSecret, CiliumNetworkPolicy)
provider "kubectl" {
  config_path    = var.enable_k8s ? pathexpand(var.k8s_config_path) : null
  config_context = var.enable_k8s ? var.k8s_context : null
}

# =============================================================================
# Kubernetes Modules (PoC)
# =============================================================================

# Vault integration for External Secrets Operator
module "k8s_vault_integration" {
  count  = var.enable_k8s ? 1 : 0
  source = "./k8s/core/vault-integration"
}

# Whoami - Stateless demo service
module "k8s_whoami" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/whoami"

  namespace = "default"
  vpa_mode  = "Off" # Recommendations only
}

# Echo - Service mesh testing
module "k8s_echo" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/echo"

  namespace       = "default"
  allowed_sources = ["whoami"]
}

# =============================================================================
# Production Migrations (004-nomad-to-k8s-migration)
# =============================================================================

# SearXNG - Metasearch engine
# OAuth authentication handled by external Traefik middleware
module "k8s_searxng" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/searxng"

  namespace = "default"
  hostname  = "searx.brmartin.co.uk"
  # Valkey runs on Nomad, accessible via Consul DNS
  valkey_url = "valkey://ollama-valkey.service.consul/1"
}

# Hubble UI - Cilium network flow visualization
# Protected by OAuth via external Traefik middleware
# Note: TLS secret must be copied to kube-system namespace manually:
#   kubectl get secret -n traefik wildcard-brmartin-tls -o yaml | \
#     sed 's/namespace: traefik/namespace: kube-system/' | kubectl apply -f -
module "k8s_hubble_ui" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/hubble-ui"

  hostname = "hubble.brmartin.co.uk"
}

# nginx-sites - Static sites (brmartin.co.uk, martinilink.co.uk)
# Multi-container: nginx + php-fpm sidecar
module "k8s_nginx_sites" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/nginx-sites"

  namespace = "default"
}

# Vaultwarden - Password manager
# Uses external PostgreSQL on martinibar.lan, GlusterFS for attachments/config
module "k8s_vaultwarden" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/vaultwarden"

  namespace = "default"
  hostname  = "bw.brmartin.co.uk"
}

# Overseerr - Media request management
# SQLite on emptyDir with litestream backup to MinIO, config on GlusterFS
module "k8s_overseerr" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/overseerr"

  namespace = "default"
  hostname  = "overseerr.brmartin.co.uk"
  # MinIO now runs on K8s, use internal service DNS
  minio_endpoint    = "http://minio-api.default.svc.cluster.local:9000"
  litestream_bucket = "overseerr-litestream"
}

# Ollama - LLM inference server with GPU
# Must run on Hestia (only GPU node)
module "k8s_ollama" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/ollama"

  namespace = "default"
}

# MinIO - Object storage for litestream backups
# Must run on Hestia where GlusterFS NFS mounts are available
# S3 API exposed via NodePort 30900 for Nomad services
module "k8s_minio" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/minio"

  namespace        = "default"
  console_hostname = "minio.brmartin.co.uk"
  data_path        = "/storage/v/glusterfs_minio_data"
}

# Keycloak - SSO provider
# Uses external PostgreSQL on martinibar.lan
module "k8s_keycloak" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/keycloak"

  namespace = "default"
  hostname  = "sso.brmartin.co.uk"
  db_host   = "192.168.1.10" # martinibar.lan
  db_port   = "5433"
}

# AppFlowy - Collaborative documentation platform
# Multi-component app: gotrue, cloud, admin-frontend, worker, web, postgres, redis
# PostgreSQL uses hostPath on Hestia (GlusterFS mount)
# MinIO used for S3 storage (already on K8s)
module "k8s_appflowy" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/appflowy"

  namespace          = "default"
  hostname           = "docs.brmartin.co.uk"
  postgres_data_path = "/storage/v/glusterfs_appflowy_postgres"
  # MinIO is now on K8s
  minio_endpoint = "http://minio-api.default.svc.cluster.local:9000"
  # Keycloak is now on K8s
  keycloak_url = "https://sso.brmartin.co.uk/realms/prod"
}

# Nextcloud - File storage and collaboration
# Uses external PostgreSQL on martinibar.lan, GlusterFS for data
# Includes Collabora for document editing
module "k8s_nextcloud" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/nextcloud"

  namespace          = "default"
  hostname           = "cloud.brmartin.co.uk"
  collabora_hostname = "collabora.brmartin.co.uk"
  db_host            = "192.168.1.10" # martinibar.lan
  db_port            = "5433"
}

# Matrix - Federated communication platform
# Components: synapse, mas, whatsapp-bridge, nginx (well-known), element, cinny
# Uses external PostgreSQL on martinibar.lan, GlusterFS for data/media/config
module "k8s_matrix" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/matrix"

  namespace        = "default"
  synapse_hostname = "matrix.brmartin.co.uk"
  mas_hostname     = "mas.brmartin.co.uk"
  element_hostname = "element.brmartin.co.uk"
  cinny_hostname   = "cinny.brmartin.co.uk"
  db_host          = "192.168.1.10" # martinibar.lan
  db_port          = "5433"
}

# GitLab - Git repository management, CI/CD, Container Registry
# Single Omnibus container with bundled services
# Uses external PostgreSQL, GlusterFS for config/data, SSH via NodePort
module "k8s_gitlab" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/gitlab"

  namespace         = "default"
  gitlab_hostname   = "git.brmartin.co.uk"
  registry_hostname = "registry.brmartin.co.uk"
  db_host           = "192.168.1.10" # martinibar.lan
  db_port           = "5433"
  ssh_port          = 2222
}

# =============================================================================
# CronJobs (Phase 11)
# =============================================================================

# Renovate - Automated dependency updates
# Runs hourly, autodiscovers all GitLab repositories
module "k8s_renovate" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/renovate"

  namespace = "default"
}

# Restic Backup - Daily backup of GlusterFS volumes
# Runs daily at 3am, backs up to local restic repository
# Must run on Hestia where backup destination is mounted
module "k8s_restic_backup" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/restic-backup"

  namespace = "default"
}

# GitLab Runner - CI/CD job execution
# Two deployments: amd64 (Hestia) and arm64 (Heracles/Nyx)
module "k8s_gitlab_runner" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/gitlab-runner"

  namespace = "default"
}

# Open WebUI - LLM chat interface
# Includes valkey (cache) and postgres (pgvector) sidecars
module "k8s_open_webui" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/open-webui"

  namespace = "default"
  hostname  = "chat.brmartin.co.uk"
}

# PlexTraktSync - Sync Plex watch history with Trakt.tv
# Runs every 2 hours
module "k8s_plextraktsync" {
  count  = var.enable_k8s ? 1 : 0
  source = "./modules-k8s/plextraktsync"

  namespace = "default"
}
