# Cluster Documentation

This directory contains documentation for the Nomad cluster infrastructure.

## Documents

### Storage

- **[nfs-ganesha-migration.md](nfs-ganesha-migration.md)** - Guide for the NFS-Ganesha migration, including the V7.2 bug workaround and building V9.4 from source.

- **[glusterfs-architecture.md](glusterfs-architecture.md)** - Overview of the GlusterFS distributed storage architecture, DHT behavior, and integration with NFS-Ganesha.

- **[storage-troubleshooting.md](storage-troubleshooting.md)** - Troubleshooting guide for common storage issues including stale handles, mount failures, and recovery procedures.

## Quick Reference

### Key Components

| Component | Purpose | Config Location |
|-----------|---------|-----------------|
| GlusterFS | Distributed storage | `gluster volume info nomad-vol` |
| NFS-Ganesha | NFS server (FSAL_GLUSTER) | `/etc/ganesha/ganesha.conf` |
| democratic-csi | CSI plugin for Nomad | `modules/plugin-csi-glusterfs/` |

### Node IPs

| Node | IP | Roles |
|------|-----|-------|
| Hestia | 192.168.1.5 | Nomad client, NFS-Ganesha V9.4 |
| Heracles | 192.168.1.6 | Nomad client, glusterd, NFS-Ganesha V9.4 |
| Nyx | 192.168.1.7 | Nomad client, glusterd, NFS-Ganesha V9.4 |

### Common Commands

```bash
# Check storage health
gluster volume status nomad-vol
ss -tlnp | grep 2049
nomad job status plugin-glusterfs-nodes

# Check for errors
dmesg | grep -i fileid
tail /var/log/ganesha/ganesha.log

# Restart CSI after storage changes
nomad job eval -force-reschedule plugin-glusterfs-nodes
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
