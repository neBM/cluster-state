# NFS-Ganesha Migration Guide

This document describes the migration from kernel NFS to NFS-Ganesha with FSAL_GLUSTER for the cluster's GlusterFS storage.

## Background

### The Problem

The cluster experienced repeated NFS "fileid changed" errors causing stale file handles, requiring **5 node reboots in 3 days**. The errors manifested as:

```
NFS: server 127.0.0.1 error: fileid changed
fsid 0:110: expected fileid 0x9b25496b44f413ac, got 0x9a372336df28293c
```

### Root Cause

The original architecture had a problematic chain:

```
GlusterFS bricks → FUSE mount → Kernel NFS re-export → democratic-csi → containers
```

**GlusterFS DHT (Distributed Hash Table) creates new GFIDs when files are renamed across bricks.** This is fundamental to distributed volumes:

1. Application (e.g., MinIO during litestream backup) creates file in temp directory
2. Application renames file to final location
3. If source and destination hash to **different bricks**, GlusterFS DHT:
   - Creates a NEW file on destination brick with a NEW GFID
   - Copies data from source to destination
   - Deletes source file
4. GlusterFS FUSE uses low 64 bits of GFID as inode number
5. NFS re-export reports new inode as fileid
6. NFS client has old fileid cached → "fileid changed" error

### The Solution

NFS-Ganesha with FSAL_GLUSTER talks directly to GlusterFS via libgfapi, which understands GFIDs natively and maintains stable fileids.

New architecture:
```
GlusterFS bricks → NFS-Ganesha (FSAL_GLUSTER via libgfapi) → democratic-csi → containers
```

## Implementation Details

### Node Configuration

| Node | IP | OS | Ganesha Version | Notes |
|------|-----|-----|-----------------|-------|
| Hestia | 192.168.1.5 | Fedora 43 (amd64) | **V9.4** (built from source) | Primary node, runs MinIO |
| Heracles | 192.168.1.6 | Ubuntu 25.10 (arm64) | **V9.4** (built from source) | GlusterFS brick |
| Nyx | 192.168.1.7 | Ubuntu 25.10 (arm64) | **V9.4** (built from source) | GlusterFS brick |

### Why Build From Source?

- **Fedora's nfs-ganesha 7.2 has a bug** (GitHub Issue #1358) where TCP listeners never start
- Ubuntu's V6.5 package worked but we standardized on V9.4 across all nodes for consistency
- V9.4 is the latest stable release with all bug fixes

### Ganesha Configuration

All nodes use the same base configuration at `/etc/ganesha/ganesha.conf`:

```
# NFS-Ganesha configuration for GlusterFS
NFS_CORE_PARAM {
    Protocols = 4;
    Bind_addr = 127.0.0.1;
}

NFSV4 {
    Delegations = false;
    Grace_Period = 15;
}

EXPORT_DEFAULTS {
    Access_Type = RW;
    Squash = No_Root_Squash;
    SecType = sys;
}

EXPORT {
    Export_Id = 1;
    Path = "/";
    Pseudo = "/storage";
    Access_Type = RW;
    Squash = No_Root_Squash;
    SecType = sys;
    Protocols = 4;
    
    CLIENT {
        Clients = 127.0.0.1;
        Access_Type = RW;
    }
    
    FSAL {
        Name = GLUSTER;
        Hostname = <glusterd-host>;  # See note below
        Volume = nomad-vol;
    }
}

LOG {
    Default_Log_Level = WARN;
    Components {
        FSAL = WARN;
        NFS4 = WARN;
    }
}
```

**FSAL Hostname configuration:**
- Hestia: `Hostname = 192.168.1.6` (points to Heracles since Hestia doesn't run glusterd)
- Heracles: `Hostname = localhost`
- Nyx: `Hostname = localhost`

### Systemd Services

All nodes use the same custom service file: `/etc/systemd/system/nfs-ganesha-local.service`

Enable with: `systemctl enable nfs-ganesha-local`

Service file (same on all nodes):
```ini
[Unit]
Description=NFS-Ganesha V9.4 file server (local build)
After=network.target glusterfs.service

[Service]
Type=forking
ExecStart=/usr/local/bin/ganesha.nfsd -f /etc/ganesha/ganesha.conf -L /var/log/ganesha/ganesha.log -N NIV_EVENT
PIDFile=/usr/local/var/run/ganesha/ganesha.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### Required Directories

All nodes (V9.4 installed to /usr/local):
```bash
mkdir -p /usr/local/var/run/ganesha
mkdir -p /usr/local/var/lib/nfs/ganesha
```

## Building Ganesha V9.4 from Source

### Fedora (amd64)

### Install Build Dependencies

```bash
dnf builddep -y nfs-ganesha
```

### Clone and Build

```bash
cd /tmp
git clone --depth 1 --branch V9.4 https://github.com/nfs-ganesha/nfs-ganesha.git
cd nfs-ganesha
git submodule update --init --recursive

mkdir build && cd build
cmake -DUSE_FSAL_GLUSTER=ON \
      -DUSE_SYSTEM_NTIRPC=OFF \
      -DUSE_FSAL_VFS=ON \
      -DUSE_DBUS=ON \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      ../src

# Fix compiler warning treated as error (GCC 15+)
sed -i 's/return std::move(input);/return input;/' ../src/monitoring/dynamic_metrics.cc

make -j$(nproc)
sudo make install
```

### Configure Library Path

```bash
# Fedora (amd64) - libraries in lib64
echo '/usr/local/lib64' | sudo tee /etc/ld.so.conf.d/ganesha.conf
sudo ldconfig
```

### Ubuntu (arm64)

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git libglusterfs-dev \
  liburcu-dev libkrb5-dev libnfsidmap-dev libdbus-1-dev \
  libcap-dev libjemalloc-dev libblkid-dev bison flex libnsl-dev libtirpc-dev

cd /tmp
git clone --depth 1 --branch V9.4 https://github.com/nfs-ganesha/nfs-ganesha.git
cd nfs-ganesha
git submodule update --init --recursive

mkdir build && cd build
cmake -DUSE_FSAL_GLUSTER=ON \
      -DUSE_SYSTEM_NTIRPC=OFF \
      -DUSE_FSAL_VFS=ON \
      -DUSE_DBUS=ON \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      ../src

# Fix compiler warning (may be needed)
sed -i 's/return std::move(input);/return input;/' ../src/monitoring/dynamic_metrics.cc

make -j$(nproc)
sudo make install

# Ubuntu (arm64) - libraries in lib (not lib64)
echo '/usr/local/lib' | sudo tee /etc/ld.so.conf.d/ganesha.conf
sudo ldconfig
```

### Verify Installation

```bash
/usr/local/bin/ganesha.nfsd -v
# Should show: NFS-Ganesha Release = V9.4
```

## Migration Procedure

### Pre-Migration Checklist

1. Ensure GlusterFS volume is healthy: `gluster volume status nomad-vol`
2. Backup critical data
3. Plan for brief service interruption

### Migration Steps

1. **Stop Docker on all nodes** (to cleanly stop containers):
   ```bash
   systemctl stop docker
   systemctl mask docker docker.socket  # Prevent auto-start during migration
   ```

2. **Stop kernel NFS on all nodes**:
   ```bash
   systemctl stop nfs-server
   systemctl disable nfs-server
   ```

3. **Create required directories** (see above)

4. **Start NFS-Ganesha on all nodes**:
   ```bash
   systemctl enable --now nfs-ganesha-local
   ```

5. **Verify Ganesha is listening on TCP 2049**:
   ```bash
   ss -tlnp | grep 2049
   # Should show: LISTEN ... [::ffff:127.0.0.1]:2049
   ```

6. **Test manual mount**:
   ```bash
   mkdir -p /mnt/test
   mount -t nfs4 127.0.0.1:/storage /mnt/test
   ls /mnt/test
   umount /mnt/test
   ```

7. **Unmask and start Docker**:
   ```bash
   systemctl unmask docker docker.socket
   systemctl start docker.socket
   systemctl start docker
   ```

8. **Restart CSI plugins**:
   ```bash
   nomad job eval -force-reschedule plugin-glusterfs-nodes
   nomad job eval -force-reschedule plugin-glusterfs-controller
   ```

9. **Verify services recover**:
   ```bash
   nomad job status
   ```

## Rollback Procedure

If Ganesha fails:

```bash
# Stop Ganesha
systemctl stop nfs-ganesha  # or nfs-ganesha-local on Hestia
systemctl disable nfs-ganesha

# Re-enable kernel NFS
systemctl enable --now nfs-server

# Restart CSI
nomad job eval -force-reschedule plugin-glusterfs-nodes
```

## Troubleshooting

### Ganesha Not Listening on TCP

**Symptom:** `ss -tlnp | grep 2049` shows nothing or only UDP

**Causes:**
1. **V7.x bug** - TCP listeners never start (Issue #1358)
   - Solution: Use V6.5 or build V9.4+ from source
   
2. **Missing PID directory**
   - Check log: `tail /var/log/ganesha/ganesha.log`
   - Look for: `open(.../ganesha.pid) failed`
   - Solution: Create the directory

3. **Missing recovery directory**
   - Look for: `Failed to create v4 recovery dir`
   - Solution: Create `/usr/local/var/lib/nfs/ganesha/` or `/var/lib/nfs/ganesha/`

### "Unable to initialize volume" Error

**Symptom:** Log shows `glusterfs_get_fs :FSAL :CRIT :Unable to initialize volume`

**Causes:**
1. Wrong hostname in FSAL config
2. GlusterFS daemon not running
3. Network connectivity issue

**Solution:**
- Verify glusterd is running: `systemctl status glusterd`
- Check volume status: `gluster volume status nomad-vol`
- Ensure FSAL Hostname points to a node running glusterd

### Stale Mounts After Migration

**Symptom:** `errno 521` (EREMOTEIO) errors, services fail to start

**Solution:**
1. Force unmount stale mounts:
   ```bash
   umount -f /path/to/mount
   ```
2. Clear kernel NFS cache:
   ```bash
   sync && echo 3 > /proc/sys/vm/drop_caches
   ```
3. Reschedule affected jobs:
   ```bash
   nomad job eval -force-reschedule <job-name>
   ```

### Checking for Fileid Errors

```bash
# Check kernel log for errors
dmesg | grep -i fileid

# Check if errors are recent (compare timestamp to uptime)
cat /proc/uptime
```

## Monitoring

### Health Checks

```bash
# Check Ganesha is running
systemctl status nfs-ganesha  # or nfs-ganesha-local

# Check TCP listener
ss -tlnp | grep 2049

# Check GlusterFS connections
ss -tnp | grep ganesha | grep ESTAB

# Check for errors in log
tail -f /var/log/ganesha/ganesha.log | grep -E '(CRIT|ERROR|FATAL)'
```

### Log Locations

- Ganesha log: `/var/log/ganesha/ganesha.log`
- Kernel NFS errors: `dmesg` or `journalctl -k`
- GlusterFS log: `/var/log/glusterfs/`

## References

- [NFS-Ganesha GitHub](https://github.com/nfs-ganesha/nfs-ganesha)
- [Issue #1358 - TCP listen UNCONN](https://github.com/nfs-ganesha/nfs-ganesha/issues/1358) - V7.x TCP bug
- [FSAL_GLUSTER documentation](https://github.com/nfs-ganesha/nfs-ganesha/wiki/FSAL_GLUSTER)
