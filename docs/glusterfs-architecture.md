# GlusterFS Architecture

This document describes the GlusterFS storage architecture used in the cluster.

## Overview

GlusterFS provides distributed storage across the cluster nodes, accessed via NFS-Ganesha and democratic-csi for container workloads.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         GlusterFS Volume: nomad-vol                      │
│                            (Distributed Mode)                            │
├─────────────────────────────────┬───────────────────────────────────────┤
│                                 │                                        │
│    Heracles (192.168.1.6)       │         Nyx (192.168.1.7)             │
│    /data/glusterfs/brick1       │         /data/glusterfs/brick1        │
│    (btrfs, nodatacow)           │         (btrfs, nodatacow)            │
│                                 │                                        │
└─────────────────────────────────┴───────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     NFS-Ganesha (FSAL_GLUSTER)                          │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ Hestia (V9.4)   │  │ Heracles (V6.5) │  │ Nyx (V6.5)      │         │
│  │ 127.0.0.1:2049  │  │ 127.0.0.1:2049  │  │ 127.0.0.1:2049  │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        democratic-csi                                    │
│                   (NFS mounts into containers)                          │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Container Workloads                                 │
│              (MinIO, GitLab, Nextcloud, Plex, etc.)                     │
└─────────────────────────────────────────────────────────────────────────┘
```

## Cluster Nodes

| Node | IP | Role | Storage |
|------|-----|------|---------|
| Hestia | 192.168.1.5 | Nomad client, NFS-Ganesha | FUSE mount only (no brick) |
| Heracles | 192.168.1.6 | Nomad client, glusterd, NFS-Ganesha | Brick 1 (btrfs) |
| Nyx | 192.168.1.7 | Nomad client, glusterd, NFS-Ganesha | Brick 2 (btrfs) |

## Volume Configuration

### Volume Details

```bash
$ gluster volume info nomad-vol

Volume Name: nomad-vol
Type: Distribute
Volume ID: 307921b6-ec98-4c31-8488-5e3830dc698a
Status: Started
Number of Bricks: 2
Transport-type: tcp
Bricks:
Brick1: 192.168.1.6:/data/glusterfs/brick1
Brick2: 192.168.1.7:/data/glusterfs/brick1
Options Reconfigured:
transport.address-family: inet
storage.fips-mode-rchecksum: on
performance.cache-size: 64MB
performance.io-thread-count: 16
network.ping-timeout: 20
```

### Volume Type: Distributed

The volume is **distributed** (not replicated), meaning:
- Data is spread across bricks based on DHT (Distributed Hash Table)
- Each file exists on only ONE brick
- **No redundancy** - if a brick fails, data on that brick is lost
- Higher aggregate capacity (sum of all bricks)

**Important:** This is NOT a replicated volume. Back up critical data!

### Brick Filesystem

Bricks run on btrfs subvolumes with `nodatacow` attribute:

```bash
# Check current setting
lsattr -d /data/glusterfs
# Should show: ---------------C------ /data/glusterfs
```

**Note:** `nodatacow` disables btrfs copy-on-write for these directories. This was originally added to prevent inode changes, but does NOT prevent the primary source of fileid changes (DHT renames).

**Warning:** Do NOT use btrfs snapshots on GlusterFS brick directories when nodatacow is set - snapshots won't preserve point-in-time data.

## Access Methods

### Via NFS-Ganesha (Recommended)

NFS-Ganesha with FSAL_GLUSTER provides the most stable access:

```bash
# Mount from localhost (each node has Ganesha)
mount -t nfs4 127.0.0.1:/storage /mnt/gluster
```

**Advantages:**
- Stable fileids (no "fileid changed" errors)
- Direct libgfapi access to GlusterFS
- Better performance than FUSE + kernel NFS

### Via FUSE (Legacy, on Hestia)

Hestia still has the FUSE mount for backward compatibility:

```bash
# Automatic mount (configured in fstab or systemd)
192.168.1.6:/nomad-vol /storage fuse.glusterfs defaults,_netdev 0 0
```

**Note:** The FUSE mount is no longer used for container storage (democratic-csi uses NFS-Ganesha).

## CSI Integration

### democratic-csi Configuration

The CSI plugin mounts volumes from NFS-Ganesha:

- Server: `127.0.0.1` (localhost - each node's Ganesha)
- Export: `/storage/v/<volume-name>`
- Protocol: NFSv4

### Volume Naming

CSI volumes follow the pattern: `glusterfs_<service>_<type>`

Examples:
- `glusterfs_minio_data`
- `glusterfs_gitlab_config`
- `glusterfs_nextcloud_data`

### Storage Paths

On Hestia (via FUSE mount or NFS):
- `/storage/v/` - GlusterFS volumes (via FUSE)
- `127.0.0.1:/storage/v/` - Same via NFS-Ganesha

## DHT Behavior and Implications

### How DHT Works

GlusterFS DHT (Distributed Hash Table) determines which brick stores each file based on a hash of the filename and parent directory.

```
hash(filename, parent_dir) → brick assignment
```

### Cross-Brick Renames

When a file is renamed and the new location hashes to a different brick:

1. **Source brick:** Original file with GFID A
2. **DHT detects:** Destination hashes to different brick
3. **DHT action:**
   - Creates NEW file on destination brick with NEW GFID B
   - Copies data from source to destination
   - Deletes source file
4. **Result:** File has a completely new GFID

This is **by design** - DHT must relocate files to maintain the hash distribution.

### Implications

1. **NFS fileids change** when GFIDs change (kernel NFS uses GFID for fileid)
2. **Heavy rename workloads** (MinIO, litestream) trigger frequent GFID changes
3. **NFS-Ganesha with FSAL_GLUSTER** handles this correctly by understanding GFIDs

## Maintenance Commands

### Check Volume Status

```bash
gluster volume status nomad-vol
```

### Check Brick Health

```bash
gluster volume heal nomad-vol info
```

### Rebalance After Adding Bricks

```bash
gluster volume rebalance nomad-vol start
gluster volume rebalance nomad-vol status
```

### Check Split-Brain (if using replication)

```bash
gluster volume heal nomad-vol info split-brain
```

## Backup Considerations

Since this is a **distributed** (non-replicated) volume:

1. **Use restic-backup job** for regular backups to MinIO
2. **Litestream** for SQLite databases (streams to MinIO)
3. **Critical data** should have application-level backups

### Restic Backup Location

```
/mnt/csi/backups/restic  (on Hestia)
```

### Litestream Backup Location

```
MinIO bucket per service (e.g., minio/<service>-litestream/)
```

## Troubleshooting

### Volume Not Mounting

```bash
# Check glusterd status
systemctl status glusterd

# Check peer status
gluster peer status

# Check volume status
gluster volume status nomad-vol
```

### Brick Offline

```bash
# Check which brick is offline
gluster volume status nomad-vol

# Check brick process
ps aux | grep glusterfsd

# Check brick log
tail -f /var/log/glusterfs/bricks/data-glusterfs-brick1.log
```

### Split-Brain Recovery (if applicable)

Only relevant if using replicated volumes. For distributed volumes, there's no split-brain - data either exists on one brick or doesn't.

## References

- [GlusterFS Documentation](https://docs.gluster.org/)
- [GlusterFS DHT](https://docs.gluster.org/en/latest/Administrator-Guide/Distributed-Hash-Table/)
- [democratic-csi](https://github.com/democratic-csi/democratic-csi)
