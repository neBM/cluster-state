# Cluster Documentation

This directory contains documentation for the K8s (K3s) cluster infrastructure.

## Documents

### Observability

- **[elasticsearch-pipelines.md](elasticsearch-pipelines.md)** - Elasticsearch ingest pipelines for K8s log processing, including sampling, noise reduction, and service-specific enrichment.

### Storage

- **[nfs-ganesha-migration.md](nfs-ganesha-migration.md)** - Guide for the NFS-Ganesha migration, including the V7.2 bug workaround and building V9.4 from source.

- **[glusterfs-architecture.md](glusterfs-architecture.md)** - Overview of the GlusterFS distributed storage architecture, DHT behavior, and integration with NFS-Ganesha.

- **[storage-troubleshooting.md](storage-troubleshooting.md)** - Troubleshooting guide for common storage issues including stale handles, mount failures, and recovery procedures.

## Quick Reference

### Key Components

| Component | Purpose | Config Location |
|-----------|---------|-----------------|
| K3s | Kubernetes distribution | `~/.kube/k3s-config` |
| GlusterFS | Distributed storage | `gluster volume info storage-vol` |
| NFS-Ganesha | NFS server (FSAL_GLUSTER) | `/etc/ganesha/ganesha.conf` |
| Elasticsearch | Log storage & search | `modules-k8s/elk/` |
| Elastic Agent | Log collection | DaemonSet in K8s |

### Node IPs

| Node | IP | Roles |
|------|-----|-------|
| Hestia | 192.168.1.5 | K3s server, NVIDIA GPU, NFS-Ganesha V9.4 |
| Heracles | 192.168.1.6 | K3s agent, glusterd, NFS-Ganesha V9.4 |
| Nyx | 192.168.1.7 | K3s agent, glusterd, NFS-Ganesha V9.4 |

### Common Commands

```bash
# K8s commands
export KUBECONFIG=~/.kube/k3s-config
kubectl get pods -n default
kubectl logs <pod-name> -n default

# Check storage health
gluster volume status storage-vol
ss -tlnp | grep 2049

# Check for errors
dmesg | grep -i fileid
tail /var/log/ganesha/ganesha.log

# Terraform
set -a && source .env && set +a
terraform plan -out=tfplan
terraform apply tfplan
```

## History

### January 2026: NFS-Ganesha Migration

**Problem:** Repeated NFS "fileid changed" errors causing stale file handles, requiring 5 node reboots in 3 days.

**Root Cause:** GlusterFS DHT creates new GFIDs when files are renamed across bricks. Kernel NFS re-export exposes this as fileid instability.

**Solution:** Migrated to NFS-Ganesha with FSAL_GLUSTER, which talks directly to GlusterFS via libgfapi and maintains stable fileids.

**Challenges:**
- Fedora's nfs-ganesha 7.2 has a bug (Issue #1358) where TCP listeners never start
- Built V9.4 from source on all nodes for consistency

**Result:** No fileid errors since migration. All nodes running NFS-Ganesha V9.4. Cluster is stable.
