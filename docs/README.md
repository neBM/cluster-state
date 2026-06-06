# Cluster Documentation

This directory contains documentation for the K8s (K3s) cluster infrastructure.

## Documents

### Observability

- **[elasticsearch-pipelines.md](elasticsearch-pipelines.md)** - Historical Elasticsearch ingest pipeline notes.

### Applications

- **[seerr-cutover.md](seerr-cutover.md)** - Seerr cutover and rollback runbook, including the legacy Overseerr redirect and storage boundaries.
- **[seerr-postgres-migration.md](seerr-postgres-migration.md)** - Planned Seerr SQLite-to-PostgreSQL migration runbook, including the maintenance-window pgloader flow and rollback caveats.

### Storage

- **[storage-troubleshooting.md](storage-troubleshooting.md)** - Current storage troubleshooting for SeaweedFS, local-path volumes, Synology NFS static PVs, and disk pressure.
- **[seaweedfs-s3-identities.md](seaweedfs-s3-identities.md)** - Current SeaweedFS S3 identities, secret mappings, and manual credential rotation/repair procedure.
- **[seaweedfs-cosi.md](seaweedfs-cosi.md)** - COSI-first SeaweedFS S3 control-plane runbook.
- **[seaweedfs-bucket-audit.md](seaweedfs-bucket-audit.md)** - Durable runbook for auditing `/buckets`, including `pvc-*` CSI paths, named S3 buckets, and cleanup candidates.
- **[seaweedfs-released-pv-audit.md](seaweedfs-released-pv-audit.md)** - Audit baseline for released SeaweedFS PVs, cleanup candidates, and retained archive volumes.
- **[litestream-recovery.md](litestream-recovery.md)** - SeaweedFS-era Litestream recovery runbook for restoring bucket contents from restic and pushing them back through the S3 gateway.
- **[seaweedfs-migration.md](seaweedfs-migration.md)** - Completed migration record from GlusterFS/NFS-Ganesha/MinIO to SeaweedFS.

### Archived Storage

- **[archived/glusterfs-architecture.md](archived/glusterfs-architecture.md)** - Historical GlusterFS architecture.
- **[archived/nfs-ganesha-migration.md](archived/nfs-ganesha-migration.md)** - Historical NFS-Ganesha migration and build notes.
- **[archived/gluster-ganesha-storage-troubleshooting.md](archived/gluster-ganesha-storage-troubleshooting.md)** - Historical Gluster/Ganesha troubleshooting runbook.

## Quick Reference

### Key Components

| Component | Purpose | Config Location |
|-----------|---------|-----------------|
| K3s | Kubernetes distribution | `clusters/k3s-homelab/` |
| SeaweedFS | RWX PVCs, S3 gateway, filer, volume servers | `infrastructure/storage/seaweedfs/` |
| local-path / local-path-retain | Node-local RWO volumes for databases and telemetry | `infrastructure/storage/storage-classes/` |
| Synology NFS static PVs | Read-only media shares for Iris and Plex | `apps/iris/`, `apps/media-centre/` |
| Grafana Alloy | Pod, journal, syslog, and auth log collection | `infrastructure/observability-core/alloy/` |
| Grafana Loki | Log storage and query backend | `infrastructure/observability-core/loki/` |

### Node IPs

| Node | IP | Roles |
|------|-----|-------|
| Hestia | 192.168.1.5 | K3s control-plane/etcd, NVIDIA GPU, local-path workloads |
| Heracles | 192.168.1.6 | K3s control-plane/etcd, SeaweedFS volume server |
| Nyx | 192.168.1.7 | K3s control-plane/etcd, SeaweedFS volume server |

### Common Commands

```bash
# K8s commands
kubectl get pods -n default
kubectl logs <pod-name> -n default

# Storage health
kubectl get pods -n default -l app=seaweedfs -o wide
kubectl get storageclass,pv,pvc -A
kubectl get events -A --field-selector reason=FreeDiskSpaceFailed --sort-by=.lastTimestamp
kubectl get nodes -o wide

# Render cluster state
./scripts/validate_kustomize.sh
kubectl kustomize clusters/k3s-homelab > /dev/null
```

## History

### January 2026: NFS-Ganesha Migration

GlusterFS DHT fileid instability under kernel NFS re-export caused repeated stale handles. The cluster migrated to NFS-Ganesha V9.4 with FSAL_GLUSTER as an interim stabilization layer.

### April-May 2026: SeaweedFS Migration and Gluster Retirement

The cluster migrated persistent workload storage and object storage to SeaweedFS, removed `glusterfs-nfs`, retired MinIO, and removed host-level GlusterFS/NFS-Ganesha services and brick data from all nodes on May 30, 2026.
