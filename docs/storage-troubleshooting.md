# Storage Troubleshooting Guide

This document covers common storage issues and their solutions for the cluster.

## Quick Diagnosis Commands

```bash
# Check all storage components
gluster volume status nomad-vol          # GlusterFS
systemctl status nfs-ganesha             # NFS-Ganesha (or nfs-ganesha-local on Hestia)
ss -tlnp | grep 2049                     # NFS TCP listener
nomad job status plugin-glusterfs-nodes  # CSI plugin

# Check for NFS errors
dmesg | grep -i fileid                   # Fileid changed errors
dmesg | grep -i nfs                      # All NFS errors
journalctl -u nfs-ganesha -f             # Ganesha logs
```

## Common Issues

### 1. NFS "fileid changed" Errors

**Symptom:**
```
NFS: server 127.0.0.1 error: fileid changed
fsid 0:110: expected fileid 0x..., got 0x...
```

**Cause:** GlusterFS DHT created new GFIDs during cross-brick rename operations. This happens with kernel NFS re-export.

**Solution:** Migrate to NFS-Ganesha with FSAL_GLUSTER. See [nfs-ganesha-migration.md](nfs-ganesha-migration.md).

**Temporary Workaround (if still on kernel NFS):**
```bash
# Clear kernel NFS cache
sync && echo 3 > /proc/sys/vm/drop_caches

# If severe, reboot the node
```

---

### 2. Stale File Handle Errors

**Symptom:**
```
Stale file handle
ls: cannot access '/path': Stale file handle
```

**Causes:**
1. NFS server restarted
2. Volume remounted
3. Fileid changed (see above)

**Solution:**
```bash
# Force unmount and remount
umount -f /path/to/mount
mount -t nfs4 127.0.0.1:/storage /path/to/mount

# For CSI mounts, reschedule the job
nomad job eval -force-reschedule <job-name>
```

---

### 3. CSI Mount Failures (errno 521)

**Symptom:**
```
mount point detection failed for volume: lstat ...: errno 521
```

**Cause:** `errno 521` is `EREMOTEIO` - remote I/O error. Usually means stale NFS mount.

**Solution:**
```bash
# Find and unmount stale mounts
mount | grep csi
umount -f /opt/nomad/data/client/csi/node/glusterfs/staging/default/<volume>/...

# Reschedule CSI plugin
nomad job eval -force-reschedule plugin-glusterfs-nodes

# Reschedule affected job
nomad job eval -force-reschedule <job-name>
```

---

### 4. Ganesha Not Starting

**Symptom:** `systemctl status nfs-ganesha` shows failed

**Check the log:**
```bash
tail -50 /var/log/ganesha/ganesha.log
journalctl -u nfs-ganesha -n 50
```

**Common causes and solutions:**

#### Missing PID directory
```
open(.../ganesha.pid) failed: No such file or directory
```
**Solution:**
```bash
# For package installation
mkdir -p /var/run/ganesha

# For V9.4 from source
mkdir -p /usr/local/var/run/ganesha
```

#### Missing recovery directory
```
Failed to create v4 recovery dir
```
**Solution:**
```bash
# For package installation
mkdir -p /var/lib/nfs/ganesha

# For V9.4 from source
mkdir -p /usr/local/var/lib/nfs/ganesha
```

#### Unable to initialize GlusterFS volume
```
glusterfs_get_fs :FSAL :CRIT :Unable to initialize volume
```
**Solution:**
1. Check glusterd is running: `systemctl status glusterd`
2. Check FSAL Hostname in config points to a glusterd node
3. Check network connectivity to glusterd

---

### 5. Ganesha Running But No TCP Listener

**Symptom:** 
```bash
$ ss -tlnp | grep 2049
# (no output, or only UDP)
```

**Cause:** Known bug in nfs-ganesha V7.x (Issue #1358)

**Solution:** 
- Use V6.5 (Ubuntu package) 
- Or build V9.4+ from source (see migration guide)

---

### 6. GlusterFS Brick Offline

**Symptom:**
```bash
$ gluster volume status nomad-vol
Brick 192.168.1.X:/data/glusterfs/brick1  N/A      N/A        N
```

**Solution:**
```bash
# Check glusterd on that node
ssh 192.168.1.X systemctl status glusterd

# Start glusterd if stopped
ssh 192.168.1.X sudo systemctl start glusterd

# Check brick process
ssh 192.168.1.X ps aux | grep glusterfsd
```

---

### 7. SSH to Nodes Hanging

**Symptom:** SSH connections to cluster nodes hang/timeout

**Causes:**
1. NFS mounts blocking SSH (PAM/NSS trying to access NFS)
2. Consul DNS issues
3. High system load

**Diagnosis:**
```bash
# Check if node is pingable
ping 192.168.1.X

# Check Nomad sees the node
nomad node status

# Try SSH with timeout
timeout 5 ssh -o ConnectTimeout=3 192.168.1.X "echo OK"
```

**Solution:**
If nodes are pingable and Nomad sees them as healthy, the SSH issue is likely PAM/NSS related. The cluster is actually healthy - just SSH is affected.

For urgent access:
- Use Nomad UI to check job status
- Use `nomad alloc exec` to access containers
- Physical console access if needed

---

### 8. Services Failing After NFS Server Change

**Symptom:** Multiple services fail to start after changing NFS configuration

**Solution:**
```bash
# Restart CSI plugins first
nomad job eval -force-reschedule plugin-glusterfs-nodes
nomad job eval -force-reschedule plugin-glusterfs-controller

# Wait for CSI to be healthy
sleep 30

# Check volume status
nomad volume status

# Reschedule failed services
nomad job eval -force-reschedule <job-name>
```

---

### 9. Litestream Backup Corruption

**Symptom:**
```
database disk image is malformed
decode error on restore
```

**Cause:** WAL/database mismatch, often from improper shutdown or NFS issues

**Solution:** Restore from restic backup

```bash
# 1. Stop affected job
nomad job stop <job-name>

# 2. Wipe corrupted litestream backup from MinIO
ssh 192.168.1.5 "docker run --rm --network host \
  -e MC_HOST_minio=http://<user>:<pass>@127.0.0.1:9000 \
  minio/mc rm --recursive --force minio/<bucket>/"

# 3. Find restic snapshot
source .env && RESTIC_PW=$(vault kv get -format=json nomad/default/restic-backup | jq -r '.data.data.RESTIC_PASSWORD')
ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 snapshots --latest 5"

# 4. Restore from restic
ssh 192.168.1.5 "docker run --rm -v /mnt/csi/backups/restic:/repo \
  -v /tmp/restore:/restore \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD='$RESTIC_PW' \
  restic/restic:0.18.1 restore <snapshot-id> \
  --include '/data/<minio-bucket>/' --target /restore"

# 5. Move restored data
ssh 192.168.1.5 "sudo mv /tmp/restore/data/<minio-bucket>/* \
  /storage/v/glusterfs_minio_data/<minio-bucket>/"

# 6. Restart job
nomad job run <job-name>
```

---

## Recovery Procedures

### Full Cluster Storage Recovery

If multiple storage components are failing:

1. **Stop all workloads:**
   ```bash
   # Mask Docker to prevent restarts
   for node in 192.168.1.{5,6,7}; do
     ssh $node "sudo systemctl stop docker; sudo systemctl mask docker docker.socket"
   done
   ```

2. **Fix GlusterFS:**
   ```bash
   # Ensure glusterd running on brick nodes
   for node in 192.168.1.{6,7}; do
     ssh $node "sudo systemctl start glusterd"
   done
   
   # Check volume
   gluster volume status nomad-vol
   ```

3. **Fix NFS-Ganesha:**
   ```bash
   # Start Ganesha on all nodes
   ssh 192.168.1.5 "sudo systemctl start nfs-ganesha-local"
   ssh 192.168.1.6 "sudo systemctl start nfs-ganesha"
   ssh 192.168.1.7 "sudo systemctl start nfs-ganesha"
   
   # Verify TCP listeners
   for node in 192.168.1.{5,6,7}; do
     ssh $node "ss -tlnp | grep 2049"
   done
   ```

4. **Restart Docker and workloads:**
   ```bash
   for node in 192.168.1.{5,6,7}; do
     ssh $node "sudo systemctl unmask docker docker.socket; sudo systemctl start docker"
   done
   
   # Restart CSI
   nomad job eval -force-reschedule plugin-glusterfs-nodes
   ```

### Emergency: Revert to Kernel NFS

If NFS-Ganesha is causing issues and you need to quickly restore service:

```bash
# On all nodes:
sudo systemctl stop nfs-ganesha  # or nfs-ganesha-local
sudo systemctl disable nfs-ganesha
sudo systemctl enable --now nfs-server

# Restart CSI
nomad job eval -force-reschedule plugin-glusterfs-nodes
```

## Monitoring Checklist

Daily/regular checks:

- [ ] All Nomad jobs running: `nomad job status`
- [ ] GlusterFS healthy: `gluster volume status nomad-vol`
- [ ] No fileid errors: `dmesg | grep -i fileid`
- [ ] Ganesha running: `systemctl status nfs-ganesha`
- [ ] Backups completing: Check restic-backup job logs

## Log Locations

| Component | Log Location |
|-----------|--------------|
| NFS-Ganesha | `/var/log/ganesha/ganesha.log` |
| GlusterFS | `/var/log/glusterfs/` |
| Kernel NFS | `dmesg`, `journalctl -k` |
| democratic-csi | `nomad alloc logs <alloc> csi-plugin` |
| Nomad | `journalctl -u nomad` |
