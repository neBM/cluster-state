# Cluster State - Agent Guide

## Overview

Infrastructure-as-Code repository for a Kubernetes (K3s) cluster. All services have been fully migrated to Kubernetes. Nomad has been decommissioned.

## Architecture

- **Kubernetes (K3s)** - Primary workload orchestration (all services)
- **Cilium** - Kubernetes CNI with network policies
- **Traefik** - Ingress controller (K8s IngressRoutes)
- **External Secrets Operator** - Syncs secrets from Vault to K8s
- **Terraform** - Infrastructure provisioning (K8s resources)
- **GlusterFS** - Distributed storage (hostPath mounts in K8s)
- **NFS-Ganesha** - NFS server with FSAL_GLUSTER (stable fileids), built from source V9.4 on all nodes
- **MinIO** - Object storage (backups, litestream)

## Documentation

See the `docs/` directory for detailed documentation:
- [docs/README.md](docs/README.md) - Documentation index
- [docs/nfs-ganesha-migration.md](docs/nfs-ganesha-migration.md) - NFS-Ganesha setup and V7.2 bug workaround
- [docs/glusterfs-architecture.md](docs/glusterfs-architecture.md) - GlusterFS architecture and DHT behavior
- [docs/storage-troubleshooting.md](docs/storage-troubleshooting.md) - Storage troubleshooting guide
- [docs/litestream-recovery.md](docs/litestream-recovery.md) - Litestream backup corruption recovery runbook

## Project Structure

```
modules-k8s/       # Kubernetes modules
  ├── <service>/
  │   ├── main.tf              # K8s deployments, services, ingress
  │   └── variables.tf         # Module variables
kubernetes.tf      # K8s module definitions
main.tf            # Terraform config
```

## Cluster Nodes

| Node | IP | Architecture | Role |
|------|-----|--------------|------|
| Hestia | 192.168.1.5 | amd64 | Primary node, NVIDIA GPU, GlusterFS client |
| Heracles | 192.168.1.6 | arm64 | Worker node, GlusterFS brick |
| Nyx | 192.168.1.7 | arm64 | Worker node, GlusterFS brick |

### Storage Paths (on Hestia)

| Path | Description |
|------|-------------|
| `/storage/v/` | GlusterFS volumes |
| `/mnt/csi/` | Legacy CSI backups |
| `/var/lib/docker/volumes/` | Docker volume backups |

## Common Commands

### Terraform

Environment variables (Vault token, etc.) must be loaded before running Terraform:

```bash
# REQUIRED before any terraform command
# set -a exports all variables, set +a stops exporting
set -a && source .env && set +a

# Plan and apply all changes
terraform plan -out=tfplan
terraform apply tfplan

# Target a specific module
terraform plan -target='module.k8s_gitlab' -out=tfplan
terraform apply tfplan
```

### Kubernetes

```bash
# Set KUBECONFIG for all kubectl commands
export KUBECONFIG=~/.kube/k3s-config

# Or prefix each command
KUBECONFIG=~/.kube/k3s-config kubectl get pods

# Common commands
kubectl get pods -n default
kubectl logs <pod-name> -n default
kubectl logs <pod-name> -n default --previous  # Previous container logs
kubectl describe pod <pod-name> -n default
kubectl exec -it <pod-name> -n default -- /bin/sh
kubectl delete pod <pod-name> -n default  # Force restart

# Check all services
kubectl get deployments,statefulsets,cronjobs -n default

# Rollout restart (redeploy without config change)
kubectl rollout restart deployment/<name> -n default
```

### SSH to Nodes

```bash
# Use /usr/bin/ssh to avoid shell aliases
/usr/bin/ssh 192.168.1.5 "command"

# Data operations (run on Hestia to avoid timeouts)
/usr/bin/ssh 192.168.1.5 "rsync -av --progress <src>/ <dst>/"
```

## Observability (Elasticsearch)

Logs are collected from all Docker containers and shipped to Elasticsearch.

### API Access

```bash
# Cluster health
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health?pretty"
```

### Common Log Queries

```bash
# Count logs by container (last hour)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_search" \
  -H "Content-Type: application/json" -d '{
  "size": 0,
  "query": {"bool": {"must": [{"range": {"@timestamp": {"gte": "now-1h"}}}]}},
  "aggs": {"by_container": {"terms": {"field": "container.name", "size": 20}}}
}' | jq '.aggregations.by_container.buckets'

# Recent logs from a specific container
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_search" \
  -H "Content-Type: application/json" -d '{
  "size": 20,
  "query": {"bool": {"must": [
    {"range": {"@timestamp": {"gte": "now-1h"}}},
    {"wildcard": {"container.name": "gitlab*"}}
  ]}},
  "sort": [{"@timestamp": "desc"}],
  "_source": ["@timestamp", "container.name", "message"]
}' | jq '.hits.hits[]._source'

# Search for errors
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_search" \
  -H "Content-Type: application/json" -d '{
  "size": 10,
  "query": {"bool": {"must": [
    {"range": {"@timestamp": {"gte": "now-1h"}}},
    {"match_phrase": {"message": "error"}}
  ]}},
  "sort": [{"@timestamp": "desc"}]
}' | jq '.hits.hits[]._source'

# Log rate per minute (useful for diagnosing noisy services)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_search" \
  -H "Content-Type: application/json" -d '{
  "size": 0,
  "query": {"bool": {"must": [
    {"range": {"@timestamp": {"gte": "now-1h"}}},
    {"wildcard": {"container.name": "SERVICE*"}}
  ]}},
  "aggs": {"per_minute": {"date_histogram": {"field": "@timestamp", "fixed_interval": "1m"}}}
}' | jq '.aggregations.per_minute.buckets[-10:] | map({time: .key_as_string, count: .doc_count})'
```

Note: The `message` field is `match_only_text` type, so it cannot be used in aggregations - only in searches.

## Naming Conventions

- GlusterFS volumes: `glusterfs_<service>_<type>`
- Martinibar volumes: `martinibar_prod_<service>_<type>`

## Storage: PVC vs hostPath

**For new services, use PVCs with the `glusterfs-nfs` StorageClass:**

```hcl
# In modules-k8s/<service>/main.tf
resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "${var.app_name}-data"
    namespace = var.namespace
    annotations = {
      # Controls directory name: /storage/v/glusterfs_<value>
      "volume-name" = "${var.app_name}_data"
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"  # Advisory only - no quota enforcement
      }
    }
  }
}

# Reference in deployment
volume {
  name = "data"
  persistent_volume_claim {
    claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
  }
}
```

**Existing services using hostPath continue to work:**
```hcl
volume {
  name = "config"
  host_path {
    path = "/storage/v/glusterfs_myapp_config"
    type = "Directory"
  }
}
```

**Key differences:**
| Aspect | PVC (recommended) | hostPath (legacy) |
|--------|-------------------|-------------------|
| Directory creation | Automatic on PVC create | Manual SSH required |
| Terraform visibility | PVC in state | No tracking |
| Data on PVC delete | Retained (Retain policy) | N/A |
| Migration effort | New services only | Existing unchanged |

## Critical Warnings

- **SQLite on Network Storage**: Use ephemeral disk with litestream for SQLite databases. Network filesystems cause locking issues.
- **SQLite WAL Mode**: Litestream requires WAL mode. Empty WAL files need a write to initialize the header.
- **Terraform lifecycle ignore_changes**: NEVER use `ignore_changes` in lifecycle blocks. It hides drift and creates confusing configs. Fix the root cause instead (e.g., remove unused fields, use `terraform state rm` to reset state).

## Debugging Tips

### Litestream Issues
- Check logs: `kubectl logs <pod> -c litestream`
- "database disk image is malformed" during checkpoint = WAL/database mismatch
- Fix: Stop allocation, restore clean database, remove `-wal` and `-shm` files, restart
- **Version compatibility**: Litestream 0.5.x uses LTX format, 0.3.x uses generations format. These are NOT compatible. Ensure restore and replicate use the same version.

### Litestream Backup Corruption Recovery
If litestream backup in MinIO is corrupted (decode errors on restore), recover from restic. See [docs/litestream-recovery.md](docs/litestream-recovery.md) for the full runbook.

### GlusterFS Architecture

```
Heracles (/data/glusterfs/brick1) ─┬─ GlusterFS "storage-vol" (Distributed)
Nyx (/data/glusterfs/brick1) ──────┘
                                   │
                                   ▼
                    NFS-Ganesha V9.4 (FSAL_GLUSTER via libgfapi)
                    ┌─────────────┬─────────────┬─────────────┐
                    │   Hestia    │  Heracles   │    Nyx      │
                    │   (V9.4)    │   (V9.4)    │   (V9.4)    │
                    └─────────────┴─────────────┴─────────────┘
                                   │
                                   ▼ (127.0.0.1:/storage)
                    nfs-subdir-external-provisioner mounts into containers
```

**Key points:**
- Bricks are on Heracles and Nyx (btrfs filesystem)
- Volume is **distributed** (data split across bricks), NOT replicated
- NFS-Ganesha with FSAL_GLUSTER provides stable fileids (no "fileid changed" errors)
- All nodes run NFS-Ganesha V9.4 built from source (no Ubuntu packages/PPAs)
- nfs-subdir-external-provisioner uses NFS to mount subdirectories into containers

See [docs/glusterfs-architecture.md](docs/glusterfs-architecture.md) for details.

### GlusterFS + Btrfs Configuration

The GlusterFS bricks run on btrfs subvolumes with `nodatacow` attribute set:
```bash
# Check current setting
/usr/bin/ssh 192.168.1.6 "lsattr -d /data/glusterfs"
/usr/bin/ssh 192.168.1.7 "lsattr -d /data/glusterfs"

# Should show 'C' flag: ---------------C------ /data/glusterfs
```

**Note:** `nodatacow` was originally added to prevent btrfs COW inode changes, but this does NOT prevent the primary source of fileid changes (see below).

**Do NOT use btrfs snapshots** on GlusterFS brick directories - with nodatacow, snapshots don't preserve point-in-time data (files are overwritten in-place).

### GlusterFS DHT and NFS fileid Instability (KNOWN ISSUE)

**Root Cause:** GlusterFS distributed volumes create **new GFIDs** when files are renamed across bricks. This is a fundamental behavior of the DHT (Distributed Hash Table) layer, not a bug.

**Mechanism:**
1. Application (e.g., MinIO during litestream backup) creates file in temp directory
2. Application renames file to final location
3. If source and destination hash to **different bricks**, GlusterFS DHT:
   - Creates a NEW file on destination brick with a NEW GFID
   - Copies data from source to destination
   - Deletes source file
4. GlusterFS FUSE uses low 64 bits of GFID as inode number
5. NFS re-export reports new inode as fileid
6. NFS client has old fileid cached → `NFS: server 127.0.0.1 error: fileid changed`

**Evidence in logs:**
```bash
# GlusterFS shows different GFIDs for source and destination:
sudo grep dht-rename /var/log/glusterfs/storage.log | tail -5
# Output shows: renaming .../file (old-gfid) => .../file (different-gfid)
```

**Why mitigations don't help:**

**Solution:** NFS-Ganesha with FSAL_GLUSTER talks directly to GlusterFS via libgfapi and maintains stable fileids. See [docs/nfs-ganesha-migration.md](docs/nfs-ganesha-migration.md).

**Previous mitigations that didn't work:**

| Mitigation | Why It Didn't Help |
|------------|---------------------|
| `nodatacow` on btrfs | Only prevents btrfs inode changes; DHT creates new GFIDs at GlusterFS layer |
| `fsid=1` on NFS export | Stabilizes filesystem ID, but fileid still comes from underlying inode |
| NFS v4.2 | Better filehandle stability, but can't fix unstable upstream inodes |
| Kernel NFS re-export | Uses GFID as fileid, which changes on cross-brick renames |

**Current status (January 2026):** Migrated to NFS-Ganesha with FSAL_GLUSTER. No fileid errors since migration.

### NFS Stale File Handle Errors
When services report "stale file handle" errors after NFS changes or node restarts:

```bash
# 1. Drop kernel caches on the affected node
/usr/bin/ssh 192.168.1.X "sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

# 2. Delete the affected pod (K8s will recreate with fresh mounts)
KUBECONFIG=~/.kube/k3s-config kubectl delete pod <pod-name> -n default
```

**Severe cases:** If kernel NFS client cache is deeply corrupted (e.g., after cluster instability or sustained fileid changes), a **full node reboot** may be required to clear the kernel NFS client cache completely.

### NFS Provisioner Issues

**PVC stuck in Pending:**
```bash
# Check provisioner logs
KUBECONFIG=~/.kube/k3s-config kubectl logs -l app=nfs-subdir-external-provisioner -n default

# Common causes:
# - NFS server unreachable (check NFS mount on provisioner node)
# - Missing volume-name annotation (check PVC annotations)
# - StorageClass not found (kubectl get storageclass glusterfs-nfs)
```

**Directory not created:**
```bash
# Check PVC events
KUBECONFIG=~/.kube/k3s-config kubectl describe pvc <pvc-name>

# Verify NFS mount on provisioner's node
KUBECONFIG=~/.kube/k3s-config kubectl get pod -l app=nfs-subdir-external-provisioner -o wide
/usr/bin/ssh <node-ip> "mount | grep storage"
```

**Verify provisioner is running:**
```bash
KUBECONFIG=~/.kube/k3s-config kubectl get pods -l app=nfs-subdir-external-provisioner
KUBECONFIG=~/.kube/k3s-config kubectl get storageclass glusterfs-nfs
```

### NVIDIA GPU / Device Plugin
Hestia has an NVIDIA GTX 1070 with time-slicing configured (2 virtual GPUs). Ollama and Plex both request GPU resources.

**GPU not visible to K8s (0 capacity):**
The NVIDIA device plugin can silently stop advertising GPUs while its pod remains Running/Ready. Symptoms: pods requesting `nvidia.com/gpu` stuck in Pending with `Insufficient nvidia.com/gpu`.

```bash
# Verify GPU works at host level
/usr/bin/ssh 192.168.1.5 "nvidia-smi"

# Check K8s GPU capacity (should show 2)
KUBECONFIG=~/.kube/k3s-config kubectl describe node hestia | grep nvidia.com/gpu

# Fix: restart the device plugin pod
KUBECONFIG=~/.kube/k3s-config kubectl delete pod -n kube-system -l app=nvidia-device-plugin-daemonset
```

### GlusterFS Socket Limitations
GlusterFS doesn't support Unix sockets. Services using sockets (Redis, Gitaly, Puma) must be configured to use:
- TCP connections instead of Unix sockets
- `/run/` (tmpfs) for socket files if sockets are required

## Observability Stack

### Prometheus (Metrics Collection)
- **URL**: https://prometheus.brmartin.co.uk
- **Purpose**: Collects and stores metrics from Kubernetes nodes, pods, and services
- **Storage**: 10GB on GlusterFS with 30-day retention
- **Scraping**: Auto-discovers targets via Kubernetes API and `prometheus.io/*` annotations

**Common queries**:
```promql
# CPU usage by node
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance) * 100)

# Memory usage by node
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Pod restarts
increase(kube_pod_container_status_restarts_total[1h])
```

### Grafana (Visualization)
- **URL**: https://grafana.brmartin.co.uk
- **Auth**: Keycloak SSO (prod realm)
- **Data Source**: Prometheus (auto-configured)
- **Storage**: 1GB on GlusterFS for dashboards and SQLite DB

**Useful dashboards** (import by ID):
- Kubernetes Cluster Overview: 6417
- Kubernetes Pods: 6336
- Node Exporter Full: 1860
- Traefik: 4475

### Meshery (Service Mesh Management)
- **URL**: https://meshery.brmartin.co.uk
- **Purpose**: Manages and visualizes Cilium service mesh
- **Features**: Service topology, performance testing, configuration management

### Adding Prometheus Metrics to Services

To expose metrics from your service to Prometheus, add these annotations to your Kubernetes Service:

```hcl
resource "kubernetes_service" "myapp" {
  metadata {
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "8080"      # Port where metrics are exposed
      "prometheus.io/path"   = "/metrics"  # Path to metrics endpoint (default: /metrics)
    }
  }
}
```

## CI/CD

### ACT Toolchain Image

The `ben/act` project in GitLab provides a multiarch CI toolchain image (`registry.brmartin.co.uk/ben/act:latest`) with:
- Terraform, Node.js 20, Python 3, uv, Java 21, Maven, Gradle, Android SDK
- Used by Athenaeum and cluster-state pipelines as the base CI image

### In-Cluster Registry Bypass

CI jobs push/pull images to the GitLab registry without going through Traefik:

1. **CoreDNS rewrite** (manual, in `coredns-custom` ConfigMap in `kube-system`): rewrites `registry.brmartin.co.uk` to the `gitlab-registry-internal` K8s service
2. **Internal service** (`modules-k8s/gitlab/main.tf`): listens on port 443 (plain HTTP), forwards to registry pod on 5000. Port 443 because GitLab's `CI_REGISTRY` variable includes `:443`
3. **registries.conf** (`modules-k8s/gitlab-runner/main.tf`): ConfigMap mounted into CI job pods at `/etc/containers/registries.conf`, marks the registry as `insecure` so buildah uses HTTP instead of TLS

### Cluster-State Pipeline

This repo has its own `.gitlab-ci.yml` with three stages:
- **validate**: `terraform fmt -check` + `terraform validate` (runs on MRs and main)
- **plan**: `terraform plan` (main only, requires PG backend connection)
- **apply**: `terraform apply` (main only, manual trigger)

**State lock gotcha**: Terraform uses a PostgreSQL backend. Concurrent or stuck pipelines can hold the state lock. Fix with:
```bash
set -a && source .env && set +a
terraform force-unlock -force <lock-id>
```

### GitLab CLI

`glab` is installed and authenticated. Prefer it over the REST API with `PRIVATE-TOKEN` — the token may not have visibility into all projects.

```bash
# List all projects
glab api projects --paginate | jq '.[].path_with_namespace'

# Retry a failed job
glab api --method POST projects/<id>/jobs/<job-id>/retry

# Get pipeline status
glab api "projects/<id>/pipelines?ref=main&status=success&per_page=1"
```

## Links

- GitLab: https://git.brmartin.co.uk
- Kibana: https://kibana.brmartin.co.uk
- Elasticsearch: https://es.brmartin.co.uk
- MinIO Console: https://minio.brmartin.co.uk
- Keycloak (SSO): https://sso.brmartin.co.uk
- Prometheus: https://prometheus.brmartin.co.uk
- Grafana: https://grafana.brmartin.co.uk
- Meshery: https://meshery.brmartin.co.uk

## Services (K8s)

| Service | Type | Notes |
|---------|------|-------|
| searxng | Deployment | Search engine |
| nginx-sites | Deployment | Static sites (brmartin.co.uk, martinilink.co.uk) |
| vaultwarden | Deployment | Password manager |
| overseerr | StatefulSet | Media requests, litestream backup |
| ollama | Deployment | LLM inference, GPU on Hestia |
| minio | Deployment | Object storage |
| keycloak | Deployment | SSO/OAuth |
| appflowy | Multiple | 7 components (cloud, gotrue, worker, web, admin, postgres, redis) |
| nextcloud | Deployment | File sync |
| matrix | Multiple | 6 components (synapse, mas, whatsapp-bridge, nginx, element, cinny) |
| gitlab | Multiple | CNG multi-container (webservice, workhorse, sidekiq, gitaly, redis, registry), SSH via NodePort 30022, external PostgreSQL |
| renovate | CronJob | Dependency updates (hourly) |
| restic-backup | CronJob | GlusterFS backup (daily 3am) |
| gitlab-runner | Deployment | CI runners (amd64 + arm64) |
| open-webui | Deployment | LLM chat UI, with valkey + postgres sidecars |
| plextraktsync | CronJob | Plex/Trakt sync (every 2 hours) |
| plex | StatefulSet | Media server, NVIDIA GPU, sqlite3 .backup CronJob to MinIO |
| jellyfin | Deployment | Alternative media server |
| tautulli | Deployment | Plex monitoring/statistics |
| elk | StatefulSet+Deployment | Elasticsearch 9.x multi-node (2 data + 1 tiebreaker) + Kibana 9.x, data on local NVMe |
| athenaeum | Multiple | Knowledge wiki (backend, frontend, redis), Keycloak SSO, Ollama for fact extraction |
| jayne-martin-counselling | Deployment | Static counselling website |

## Active Technologies
- HCL (Terraform 1.x), YAML (K8s manifests via Terraform kubernetes provider)
- Kubernetes (K3s 1.34+), Cilium CNI, Traefik Ingress, External Secrets Operator
- GlusterFS via NFS-Ganesha at `/storage/v/` on all nodes
- NFS Subdir External Provisioner for dynamic PVC provisioning
- MinIO (litestream backups)
- Elasticsearch 9.x multi-node cluster (2 data nodes + 1 voting-only tiebreaker)
- Kibana 9.x (K8s Deployment)
- GitLab CNG container images (registry.gitlab.com/gitlab-org/build/cng)
- External PostgreSQL (192.168.1.10:5433) for GitLab
- local-path-retain StorageClass for ES data nodes (50GB each on local NVMe)

## Recent Changes
- 010-observability-stack: Added Prometheus, Grafana, and Meshery for cluster observability
- 009-es-multi-node-cluster: Migrated Elasticsearch from single-node on GlusterFS to 3-node cluster (2 data + 1 tiebreaker) on local NVMe storage
- 008-gitlab-multi-container: Migrated GitLab from Omnibus to CNG multi-container architecture (webservice, workhorse, sidekiq, gitaly, redis, registry)
- 007-jayne-martin-k8s-migration: Migrated Jayne Martin Counselling to Kubernetes, decommissioned Nomad
- 006-elk-k8s-migration: Migrated ELK stack from Nomad to Kubernetes
- 005-k8s-volume-provisioning: Added NFS Subdir External Provisioner for automatic PVC directory creation
- 004-nomad-to-k8s-migration: Migrated most services from Nomad to Kubernetes (K3s)
