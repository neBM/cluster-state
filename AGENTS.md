# Cluster State - Agent Guide

## Overview

Infrastructure-as-Code repository for a hybrid Nomad/Kubernetes cluster. Most services have been migrated to Kubernetes (K3s), with a few remaining on Nomad.

## Architecture

- **Kubernetes (K3s)** - Primary workload orchestration (most services)
- **Nomad** - Secondary orchestration (elk, jayne-martin-counselling)
- **Cilium** - Kubernetes CNI with network policies
- **Traefik** - Ingress controller (K8s IngressRoutes)
- **External Secrets Operator** - Syncs secrets from Vault to K8s
- **Terraform** - Infrastructure provisioning (both Nomad and K8s resources)
- **GlusterFS** - Distributed storage (hostPath mounts in K8s)
- **NFS-Ganesha** - NFS server with FSAL_GLUSTER (stable fileids), built from source V9.4 on all nodes
- **MinIO** - Object storage (backups, litestream)

## Documentation

See the `docs/` directory for detailed documentation:
- [docs/README.md](docs/README.md) - Documentation index
- [docs/nfs-ganesha-migration.md](docs/nfs-ganesha-migration.md) - NFS-Ganesha setup and V7.2 bug workaround
- [docs/glusterfs-architecture.md](docs/glusterfs-architecture.md) - GlusterFS architecture and DHT behavior
- [docs/storage-troubleshooting.md](docs/storage-troubleshooting.md) - Storage troubleshooting guide

## Project Structure

```
modules-k8s/       # Kubernetes modules (primary)
  ├── <service>/
  │   ├── main.tf              # K8s deployments, services, ingress
  │   └── variables.tf         # Module variables
modules/           # Nomad modules (legacy, few remaining)
  ├── <service>/
  │   ├── main.tf              # Terraform config, CSI volumes
  │   └── jobspec.nomad.hcl    # Nomad job definition
kubernetes.tf      # K8s module definitions
main.tf            # Nomad module definitions + CSI plugins
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

Environment variables (Nomad token, Vault token, etc.) must be loaded before running Terraform:

```bash
# REQUIRED before any terraform command
# set -a exports all variables, set +a stops exporting
set -a && source .env && set +a

# Plan and apply all changes (includes both K8s and Nomad)
terraform plan -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
terraform apply tfplan

# Target a specific K8s module
terraform plan -target='module.k8s_gitlab' -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
terraform apply tfplan

# Target a specific Nomad module
terraform plan -target=module.elk -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
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

### Nomad (for remaining services)

```bash
nomad job status <job>
nomad alloc logs <alloc> <task>
nomad alloc logs -tail -n 50 <alloc> <task>
nomad alloc exec -task <task> <alloc> <command>
nomad volume status

# Force reschedule a job (useful after fixing issues)
nomad job eval -force-reschedule <job-name>
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

## Critical Warnings

- **CSI Volume Deletion**: `nomad volume delete` AND `terraform destroy` of `nomad_csi_volume` resources **delete the underlying data**. Always backup first or use `terraform state rm` to remove from state without destroying.
- **SQLite on Network Storage**: Use ephemeral disk with litestream for SQLite databases. Network filesystems cause locking issues.
- **SQLite WAL Mode**: Litestream requires WAL mode. Empty WAL files need a write to initialize the header.
- **Consul Connect Sidecar Memory**: Default 128MB is insufficient for envoy proxy (~90-130MB baseline). Set `memory=256, memory_max=512` to prevent OOM kills that cascade across services.
- **Terraform lifecycle ignore_changes**: NEVER use `ignore_changes` in lifecycle blocks. It hides drift and creates confusing configs. Fix the root cause instead (e.g., remove unused fields, use `terraform state rm` to reset state).

## Debugging Tips

### Litestream Issues
- Check logs: `kubectl logs <pod> -c litestream` (K8s) or `nomad alloc logs <alloc> litestream` (Nomad)
- "database disk image is malformed" during checkpoint = WAL/database mismatch
- Fix: Stop allocation, restore clean database, remove `-wal` and `-shm` files, restart
- **Version compatibility**: Litestream 0.5.x uses LTX format, 0.3.x uses generations format. These are NOT compatible. Ensure restore and replicate use the same version.

### Litestream Backup Corruption Recovery
If litestream backup in MinIO is corrupted (decode errors on restore), recover from restic:

```bash
# 1. Stop the affected service (K8s)
KUBECONFIG=~/.kube/k3s-config kubectl scale statefulset/<name> --replicas=0 -n default
# Or for Nomad:
# nomad job stop <job-name>

# 2. Wipe corrupted litestream backup from MinIO
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /storage/v/glusterfs_minio_data/<bucket>/db/*"

# 3. Find latest good restic snapshot
set -a && source .env && set +a
RESTIC_PW=$(vault kv get -format=json nomad/default/restic-backup | jq -r '.data.data.RESTIC_PASSWORD')
/usr/bin/ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 snapshots --latest 5"

# 4. Restore litestream LTX files from restic
/usr/bin/ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -v /tmp/restore:/restore \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 restore <snapshot-id> \
  --include '/data/glusterfs_minio_data/<bucket>/' --target /restore"

# 5. Move restored data to MinIO volume
/usr/bin/ssh 192.168.1.5 "sudo mv /tmp/restore/data/glusterfs_minio_data/<bucket>/db/* \
  /storage/v/glusterfs_minio_data/<bucket>/db/"

# 6. Clean up and restart
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /tmp/restore"
KUBECONFIG=~/.kube/k3s-config kubectl scale statefulset/<name> --replicas=1 -n default
# Or for Nomad:
# nomad job run <job-name>
```

### GlusterFS Architecture

```
Heracles (/data/glusterfs/brick1) ─┬─ GlusterFS "nomad-vol" (Distributed)
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
                          democratic-csi mounts into containers
```

**Key points:**
- Bricks are on Heracles and Nyx (btrfs filesystem)
- Volume is **distributed** (data split across bricks), NOT replicated
- NFS-Ganesha with FSAL_GLUSTER provides stable fileids (no "fileid changed" errors)
- All nodes run NFS-Ganesha V9.4 built from source (no Ubuntu packages/PPAs)
- CSI plugin uses NFS to mount subdirectories into containers

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

### GlusterFS Issues
- K8s uses hostPath mounts to `/storage/v/` (NFS-mounted GlusterFS)
- DHT fileid instability is inherent to distributed volumes with NFS re-export

### NFS Stale File Handle Errors
When services report "stale file handle" errors after NFS changes or node restarts:

```bash
# 1. Drop kernel caches on the affected node
/usr/bin/ssh 192.168.1.X "sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

# 2. Delete the affected pod (K8s will recreate with fresh mounts)
KUBECONFIG=~/.kube/k3s-config kubectl delete pod <pod-name> -n default

# For Nomad services:
# nomad alloc stop <alloc-id>
```

**Severe cases:** If kernel NFS client cache is deeply corrupted (e.g., after cluster instability or sustained fileid changes), a **full node reboot** may be required to clear the kernel NFS client cache completely.

### GlusterFS Socket Limitations
GlusterFS doesn't support Unix sockets. Services using sockets (Redis, Gitaly, Puma) must be configured to use:
- TCP connections instead of Unix sockets
- `/run/` (tmpfs) for socket files if sockets are required

## Links

- GitLab: https://git.brmartin.co.uk
- Kibana: https://kibana.brmartin.co.uk
- Elasticsearch: https://es.brmartin.co.uk
- MinIO Console: https://minio.brmartin.co.uk
- Keycloak (SSO): https://sso.brmartin.co.uk
- Nomad UI: https://nomad.brmartin.co.uk:443

## Migrated Services (K8s)

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
| nextcloud | Deployment | File sync, with Collabora sidecar |
| matrix | Multiple | 6 components (synapse, mas, whatsapp-bridge, nginx, element, cinny) |
| gitlab | Deployment | Git hosting, SSH via NodePort 30022 |
| renovate | CronJob | Dependency updates (hourly) |
| restic-backup | CronJob | GlusterFS backup (daily 3am) |
| gitlab-runner | Deployment | CI runners (amd64 + arm64) |
| open-webui | Deployment | LLM chat UI, with valkey + postgres sidecars |
| plextraktsync | CronJob | Plex/Trakt sync (every 2 hours) |
| plex | StatefulSet | Media server, NVIDIA GPU, litestream 0.5 backup |
| jellyfin | Deployment | Alternative media server |
| tautulli | Deployment | Plex monitoring/statistics |

## Remaining on Nomad

| Service | Reason |
|---------|--------|
| elk | Complex 3-node Elasticsearch cluster |
| jayne-martin-counselling | Simple static site |

## Active Technologies
- HCL (Terraform 1.x), YAML (K8s manifests via Terraform kubernetes provider)
- Kubernetes (K3s), Cilium CNI, Traefik Ingress, External Secrets Operator
- GlusterFS (hostPath mounts), MinIO (litestream backups), NFS-Ganesha
- Nomad for remaining services (elk, jayne-martin-counselling)

## Recent Changes
- 004-nomad-to-k8s-migration: Migrated most services from Nomad to Kubernetes (K3s)
