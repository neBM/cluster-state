# Kubernetes Configuration
#
# This file configures the Kubernetes provider and K8s-based modules.
# The K8s cluster (K3s) must be installed separately.

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

# Kubernetes provider
provider "kubernetes" {
  config_path    = pathexpand(var.k8s_config_path)
  config_context = var.k8s_context
}

# kubectl provider for CRDs (VPA, ExternalSecret, CiliumNetworkPolicy)
provider "kubectl" {
  config_path    = pathexpand(var.k8s_config_path)
  config_context = var.k8s_context
}

# =============================================================================
# Core Infrastructure
# =============================================================================

# NFS Subdir External Provisioner - Dynamic volume provisioning for GlusterFS/NFS
# Creates directories automatically when PVCs are created
# Directory naming: glusterfs_<service>_<type> via volume-name annotation
module "k8s_nfs_provisioner" {
  source = "./modules-k8s/nfs-provisioner"

  namespace          = "default"
  nfs_server         = "127.0.0.1"
  nfs_path           = "/storage/v"
  storage_class_name = "glusterfs-nfs"
  reclaim_policy     = "Retain"
}

# Vault integration for External Secrets Operator
module "k8s_vault_integration" {
  source = "./k8s/core/vault-integration"
}

# CI Service Account for GitLab CI/CD pipelines
# Provides limited RBAC permissions for Terraform to manage K8s resources
module "k8s_ci_service_account" {
  source = "./modules-k8s/ci-service-account"

  namespace            = "default"
  service_account_name = "terraform-ci"
}

# Goldilocks - Automatic VPA creation and recommendations
# Creates VPAs for all Deployments/StatefulSets in labeled namespaces
# VPAs start in "Off" mode (recommendations only, no auto-scaling)
module "k8s_goldilocks" {
  source = "./modules-k8s/goldilocks"

  namespace          = "kube-system"
  enabled_namespaces = ["default"]
  default_vpa_mode   = "Off"
  enable_dashboard   = true
  dashboard_host     = "goldilocks.brmartin.co.uk"
  # OAuth handled by external Traefik, no K8s middleware needed
  dashboard_middlewares = []
}

# Whoami - Stateless demo service
module "k8s_whoami" {
  source = "./modules-k8s/whoami"

  namespace = "default"
  vpa_mode  = "Off" # Recommendations only
}

# Echo - Service mesh testing
module "k8s_echo" {
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
  source = "./modules-k8s/hubble-ui"

  hostname = "hubble.brmartin.co.uk"
}

# nginx-sites - Static sites (brmartin.co.uk, martinilink.co.uk)
# Multi-container: nginx + php-fpm sidecar
module "k8s_nginx_sites" {
  source = "./modules-k8s/nginx-sites"

  namespace = "default"
}

# Vaultwarden - Password manager
# Uses external PostgreSQL on martinibar.lan, GlusterFS for attachments/config
module "k8s_vaultwarden" {
  source = "./modules-k8s/vaultwarden"

  namespace = "default"
  hostname  = "bw.brmartin.co.uk"
}

# Overseerr - Media request management
# SQLite on emptyDir with litestream backup to MinIO, config on GlusterFS
module "k8s_overseerr" {
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
  source = "./modules-k8s/ollama"

  namespace = "default"
}

# MinIO - Object storage for litestream backups
# Must run on Hestia where GlusterFS NFS mounts are available
# S3 API exposed via NodePort 30900 for Nomad services
module "k8s_minio" {
  source = "./modules-k8s/minio"

  namespace        = "default"
  console_hostname = "minio.brmartin.co.uk"
  data_path        = "/storage/v/glusterfs_minio_data"
}

# Keycloak - SSO provider
# Uses external PostgreSQL on martinibar.lan
module "k8s_keycloak" {
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
  source = "./modules-k8s/renovate"

  namespace = "default"
}

# Restic Backup - Daily backup of GlusterFS volumes
# Runs daily at 3am, backs up to local restic repository
# Must run on Hestia where backup destination is mounted
module "k8s_restic_backup" {
  source = "./modules-k8s/restic-backup"

  namespace = "default"
}

# GitLab Runner - CI/CD job execution
# Two deployments: amd64 (Hestia) and arm64 (Heracles/Nyx)
module "k8s_gitlab_runner" {
  source = "./modules-k8s/gitlab-runner"

  namespace = "default"
}

# Open WebUI - LLM chat interface
# Includes valkey (cache) and postgres (pgvector) sidecars
module "k8s_open_webui" {
  source = "./modules-k8s/open-webui"

  namespace = "default"
  hostname  = "chat.brmartin.co.uk"
}

# PlexTraktSync - Sync Plex watch history with Trakt.tv
# Runs every 2 hours
module "k8s_plextraktsync" {
  source = "./modules-k8s/plextraktsync"

  namespace = "default"
}

# Media Centre - Plex, Jellyfin, Tautulli
# Plex requires NVIDIA GPU on Hestia node
module "k8s_media_centre" {
  source = "./modules-k8s/media-centre"

  namespace = "default"
}

# =============================================================================
# Jayne Martin Counselling Migration (007-jayne-martin-k8s-migration)
# =============================================================================

# Jayne Martin Counselling - Static website
# Previously running on Nomad, migrated to K8s for consistency
module "k8s_jayne_martin_counselling" {
  source = "./modules-k8s/jayne-martin-counselling"

  namespace = "default"
  vpa_mode  = "Off" # Recommendations only
}

# =============================================================================
# ELK Stack Migration (006-elk-k8s-migration)
# =============================================================================

# ELK Stack - Elasticsearch and Kibana
# Single-node Elasticsearch cluster on GlusterFS
# Migrated from 3-node Nomad cluster
module "k8s_elk" {
  source = "./modules-k8s/elk"

  namespace        = "default"
  es_hostname      = "es.brmartin.co.uk"
  kibana_hostname  = "kibana.brmartin.co.uk"
  es_data_path     = "/storage/v/glusterfs_elasticsearch_data"
  es_image_tag     = "9.2.3"
  kibana_image_tag = "9.2.3"

  # Increased from 1Gi - OOM during Fleet policy deployment
  kibana_memory_request = "1Gi"
  kibana_memory_limit   = "2Gi"
}

# =============================================================================
# Observability
# =============================================================================

# Elastic Agent - K8s log collection via Fleet
# DaemonSet collects container logs from all nodes
# Enrollment token stored in elastic-system/elastic-agent-enrollment secret
module "k8s_elastic_agent" {
  source = "./modules-k8s/elastic-agent"

  namespace                    = "elastic-system"
  fleet_url                    = "https://192.168.1.5:8220" # hestia.lan - use IP for K8s DNS compatibility
  fleet_insecure               = true                       # Fleet Server uses self-signed cert
  enrollment_token_secret_name = "elastic-agent-enrollment"
  enrollment_token_secret_key  = "token"
  elastic_agent_image          = "docker.elastic.co/elastic-agent/elastic-agent:9.2.4"
}
