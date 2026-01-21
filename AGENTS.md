# Cluster State - Agent Guide

## Overview

Infrastructure-as-Code repository for a Nomad cluster. Services are deployed via Terraform which submits Nomad jobspecs.

## Architecture

- **Nomad** - Workload orchestration
- **Consul** - Service mesh (transparent proxy mode)
- **Terraform** - Infrastructure provisioning
- **GlusterFS** - Distributed storage (CSI volumes)
- **Martinibar (NFS)** - Legacy storage (migrating away)
- **MinIO** - Object storage (backups, litestream)

## Project Structure

```
modules/           # Terraform modules, each containing jobspecs
  ├── <service>/
  │   ├── main.tf              # Terraform config, CSI volumes
  │   └── jobspec.nomad.hcl    # Nomad job definition
main.tf            # Root terraform config
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

# Plan and apply all changes
terraform plan -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
terraform apply tfplan

# Target a specific module (faster for single-service changes)
terraform plan -target=module.gitlab -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
terraform apply tfplan
```

### Nomad

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

- **CSI Volume Deletion**: `nomad volume delete` deletes the underlying data. Always backup first.
- **SQLite on Network Storage**: Use ephemeral disk with litestream for SQLite databases. Network filesystems cause locking issues.
- **SQLite WAL Mode**: Litestream requires WAL mode. Empty WAL files need a write to initialize the header.
- **Consul Connect Sidecar Memory**: Default 128MB is insufficient for envoy proxy (~90-130MB baseline). Set `memory=256, memory_max=512` to prevent OOM kills that cascade across services.

## Debugging Tips

### Litestream Issues
- Check logs: `nomad alloc logs <alloc> litestream`
- "database disk image is malformed" during checkpoint = WAL/database mismatch
- Fix: Stop allocation, restore clean database, remove `-wal` and `-shm` files, restart

### Litestream Backup Corruption Recovery
If litestream backup in MinIO is corrupted (decode errors on restore), recover from restic:

```bash
# 1. Stop the affected job
nomad job stop <job-name>

# 2. Wipe corrupted litestream backup from MinIO
/usr/bin/ssh 192.168.1.5 "docker run --rm --network host \
  -e MC_HOST_minio=http://<user>:<pass>@127.0.0.1:9000 \
  minio/mc rm --recursive --force minio/<bucket>/"

# 3. Find latest good restic snapshot
source .env && RESTIC_PW=$(vault kv get -format=json nomad/default/restic-backup | jq -r '.data.data.RESTIC_PASSWORD')
/usr/bin/ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 snapshots --latest 5"

# 4. Restore litestream LTX files from restic
/usr/bin/ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -v /tmp/restore:/restore \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 restore <snapshot-id> \
  --include '/data/<minio-bucket>/' --target /restore"

# 5. Move restored data to MinIO volume
/usr/bin/ssh 192.168.1.5 "sudo mv /tmp/restore/data/<minio-bucket>/* \
  /storage/v/glusterfs_minio_data/<minio-bucket>/"

# 6. Restart the job - litestream will restore from the recovered backup
nomad job run <job-name>
```

### GlusterFS Architecture

```
Heracles (/data/glusterfs/brick1) ─┬─ GlusterFS "nomad-vol" (Distributed)
Nyx (/data/glusterfs/brick1) ──────┘
                                   │
                                   ▼
All nodes ─── FUSE mount (localhost:/nomad-vol → /storage)
                                   │
                                   ▼
                          NFS re-export (127.0.0.1:/storage/v/*)
                                   │
                                   ▼
                          democratic-csi mounts into containers
```

**Key points:**
- Bricks are on Heracles and Nyx (btrfs filesystem)
- Volume is **distributed** (data split across bricks), NOT replicated
- Each node has its own FUSE mount and local NFS re-export
- CSI plugin uses NFS to mount subdirectories into containers

### GlusterFS + Btrfs Configuration

The GlusterFS bricks run on btrfs subvolumes. To prevent NFS "fileid changed" errors caused by btrfs copy-on-write:

**Required:** `nodatacow` attribute on brick directories:
```bash
# Check current setting
/usr/bin/ssh 192.168.1.6 "lsattr -d /data/glusterfs"
/usr/bin/ssh 192.168.1.7 "lsattr -d /data/glusterfs"

# Should show 'C' flag: ---------------C------ /data/glusterfs
```

**Why:** Btrfs COW causes inode changes that propagate through GlusterFS to NFS, causing stale file handles. `nodatacow` disables COW for data (metadata COW still occurs).

**Trade-off:** nodatacow disables btrfs checksums for file data. GlusterFS has its own integrity mechanisms.

**Do NOT use btrfs snapshots** on GlusterFS brick directories - with nodatacow, snapshots don't preserve point-in-time data (files are overwritten in-place).

### GlusterFS Issues
- Mount options configured in `modules/plugin-csi-glusterfs/`

### NFS Stale File Handle Errors
When services report "stale file handle" errors after NFS changes or node restarts:

```bash
# 1. Drop kernel caches on the affected node
/usr/bin/ssh 192.168.1.X "sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches"

# 2. Restart the CSI node plugin if needed
nomad job eval -force-reschedule plugin-glusterfs-nodes

# 3. Reschedule the affected job
nomad job eval -force-reschedule <job-name>
```

If the above doesn't work (mount still shows `d?????????`), stop the affected allocation to force fresh mounts:
```bash
# Find and stop the allocation with stale mounts
nomad alloc stop <alloc-id>
# Nomad will automatically reschedule with fresh CSI mounts
```

**Severe cases:** If kernel NFS client cache is deeply corrupted (e.g., after cluster instability or MinIO OOM cascade), the above steps may not work. In this case, a **full node reboot** is required to clear the kernel NFS client cache completely.

### GlusterFS Socket Limitations
GlusterFS doesn't support Unix sockets. Services using sockets (Redis, Gitaly, Puma) must be configured to use:
- TCP connections instead of Unix sockets
- `/run/` (tmpfs) for socket files if sockets are required

## Links

- Nomad UI: https://nomad.brmartin.co.uk:443
- Kibana: https://kibana.brmartin.co.uk
- Elasticsearch: https://es.brmartin.co.uk

## Active Technologies
- HCL (Terraform 1.x, Nomad jobspec) + Nomad, Consul Connect, Traefik, Litestream, MinIO (001-migrate-overseerr-nomad)
- Ephemeral disk (SQLite via litestream), GlusterFS CSI (config files) (001-migrate-overseerr-nomad)

## Recent Changes
- 001-migrate-overseerr-nomad: Added HCL (Terraform 1.x, Nomad jobspec) + Nomad, Consul Connect, Traefik, Litestream, MinIO
