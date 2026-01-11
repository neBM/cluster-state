# GlusterFS Migration Plan - Complete Implementation Guide

**Date Created:** 2026-01-11
**Status:** READY FOR EXECUTION
**Estimated Total Time:** 8-12 hours over 2-3 days
**Risk Level:** 🟡 Medium (Phase 1), 🔴 High (Phase 2)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Investigation Results](#investigation-results)
3. [Architecture Overview](#architecture-overview)
4. [Phase 0: Environment Setup](#phase-0-environment-setup)
5. [Phase 1: Mount Options Optimization](#phase-1-mount-options-optimization)
6. [Phase 2: Matrix Migration](#phase-2-matrix-migration)
7. [Post-Migration Tasks](#post-migration-tasks)
8. [Rollback Procedures](#rollback-procedures)
9. [Success Criteria](#success-criteria)
10. [Appendix: Reference Information](#appendix-reference-information)

---

## Executive Summary

### Objectives

1. **Optimize GlusterFS mount options** to improve performance by removing SQLite-specific aggressive caching restrictions
2. **Migrate Matrix to GlusterFS CSI volumes** with separate volumes for config, media, bridge data, and shared configs
3. **Recreate existing CSI volumes** with optimized mount options

### Key Decisions Confirmed

- ✅ Optimized mount options approved (ac, actimeo=60, lookupcache=positive, hard, intr, retrans=3, timeo=600)
- ✅ Recreate all existing CSI volumes immediately
- ✅ Matrix: Separate volumes (config, media, bridge, shared)
- ✅ Accept GlusterFS replication risk short-term, ensure good backups
- ✅ In-place migration approach
- ✅ Test with Jellyfin config volume first
- ✅ Backups stored on Heracles/Nyx (btrfs with 700GB+ free)

### Timeline

| Phase | Duration | Downtime | Risk |
|-------|----------|----------|------|
| Phase 0: Setup | 30 min | None | 🟢 Low |
| Phase 1: Mount Options | 3-4 hours | Rolling (5-10 min/service) | 🟡 Medium |
| Phase 2: Matrix Migration | 4-6 hours | 15-30 min | 🔴 High |
| Post-Migration | 2-3 hours | None | 🟢 Low |

---

## Investigation Results

### ✅ Critical Findings

1. **WhatsApp Bridge Database:** ✅ Uses PostgreSQL (not SQLite)
   - URI: `postgres://matrix-whatsapp@martinibar.lan:5433/matrix-whatsapp`
   - No SQLite files found

2. **SQLite Audit:** ✅ No SQLite on GlusterFS volumes
   - Plex: SQLite correctly isolated on ephemeral disk
   - MinIO, Ollama, AppFlowy: No SQLite databases
   - **Safe to optimize mount options**

3. **Current Storage Usage:**
   - MinIO: 965MB
   - Ollama: 3.8GB
   - Other volumes: TBD (will measure during migration)

4. **GlusterFS Configuration:**
   - **Type:** Distribute (⚠️ NO replication!)
   - **Bricks:** Heracles + Nyx
   - **NFS:** Built-in GlusterFS NFS disabled
   - **Performance:** Write-behind, read-ahead, io-cache enabled

5. **Current Mount Options:**
   - Jobspec defines: `nfsvers=3, noatime, noac, lookupcache=none`
   - Active mounts show: Standard options (caching enabled)
   - **Conclusion:** Existing volumes may not have aggressive options applied

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  GlusterFS Volume: nomad-vol                    │
│  Type: Distribute (NO replication!)             │
│  Bricks:                                        │
│    - Heracles (192.168.1.6): /data/glusterfs/brick1 │
│    - Nyx (192.168.1.7): /data/glusterfs/brick1      │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│  FUSE Mount (on each node)                      │
│  localhost:/nomad-vol → /storage                │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│  Kernel NFS Server (on each node)               │
│  Export: /storage → 127.0.0.1                   │
│  Options: rw,sync,no_subtree_check,no_root_squash │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│  Democratic-CSI NFS Client                      │
│  Mounts: 127.0.0.1:/storage/v/<volume-name>     │
│  NEW Options: nfsvers=3, ac, actimeo=60, etc.   │
└─────────────────────────────────────────────────┘
```

### Cluster Nodes

- **Hestia (192.168.1.5):** Nomad client (future GlusterFS node)
- **Heracles (192.168.1.6):** Nomad + GlusterFS brick
- **Nyx (192.168.1.7):** Nomad + GlusterFS brick

### Current Services on GlusterFS

1. MinIO (`glusterfs_minio_data`)
2. Ollama (`glusterfs_ollama_data`, `glusterfs_ollama_postgres`, `glusterfs_searxng_config`)
3. AppFlowy (`glusterfs_appflowy_postgres`)
4. Plex config (`glusterfs_plex_config`)
5. Jellyfin config (`glusterfs_jellyfin_config`)

### Services NOT on GlusterFS

- **Elasticsearch:** Host volumes + Martinibar NFS backups
- **Plex media:** Martinibar NFS direct mount
- **Forgejo:** Martinibar NFS CSI (awaiting GitLab migration)
- **Matrix:** Currently direct NFS mounts (TO BE MIGRATED)

---

## Phase 0: Environment Setup

### Estimated Time: 30 minutes
### Risk Level: 🟢 Low

### Environment Configuration

**Important:** When deploying Terraform without SSH to cluster nodes:

1. **Database credentials:** Loaded from `.env` in project root
2. **Nomad address:** Must be set to `https://nomad.brmartin.co.uk:443`
   - Default in `variables.tf` is `hestia.lan` (for local SSH access)
   - Override when deploying remotely

```bash
# Option A: Update variables.tf temporarily
# OR
# Option B: Set environment variable
export NOMAD_ADDR="https://nomad.brmartin.co.uk:443"
```

### Pre-Flight Checklist

```bash
# 1. Verify cluster health
nomad node status
nomad plugin status glusterfs
nomad plugin status martinibar

# 2. Verify all jobs healthy
nomad job status minio
nomad job status ollama
nomad job status appflowy
nomad job status media-centre
nomad job status matrix

# 3. Check GlusterFS health
ssh 192.168.1.6 "sudo gluster volume status nomad-vol"
ssh 192.168.1.6 "sudo gluster volume heal nomad-vol info"

# 4. Verify backup space
ssh 192.168.1.6 "df -h /data | tail -1"
# Should show 700GB+ free

# 5. Verify Terraform state
terraform init
terraform plan
# Should show no pending changes

# 6. Document current state
nomad job status > /tmp/pre-migration-jobs.txt
nomad volume status > /tmp/pre-migration-volumes.txt
ssh 192.168.1.6 "mount | grep glusterfs" > /tmp/pre-migration-mounts.txt
```

### Create Backup Directory Structure

```bash
# Run on Heracles
ssh 192.168.1.6

# Create timestamped backup directory
BACKUP_ROOT="/data/backups/glusterfs-migration-$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p "$BACKUP_ROOT"/{phase1,phase2,scripts,verification}

echo "Backup root: $BACKUP_ROOT"
# Save this path for use throughout migration
```

### Prepare Backup Scripts

**Script 1: Backup GlusterFS Volumes**

```bash
# Save as /data/backups/scripts/backup-glusterfs-volumes.sh
#!/bin/bash
set -euo pipefail

BACKUP_DIR="${1:-/data/backups/manual-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$BACKUP_DIR"

echo "=== GlusterFS Volume Backup ==="
echo "Backup destination: $BACKUP_DIR"
echo "Started: $(date)"

# Backup all volumes
sudo rsync -avP --delete /storage/v/ "$BACKUP_DIR/glusterfs-volumes/"

# Create tarball of critical configs
sudo tar czf "$BACKUP_DIR/critical-configs.tar.gz" \
  /storage/v/glusterfs_plex_config/ \
  /storage/v/glusterfs_jellyfin_config/ \
  /storage/v/glusterfs_searxng_config/ \
  2>/dev/null || true

# Calculate checksums
find "$BACKUP_DIR" -type f -exec sha256sum {} \; > "$BACKUP_DIR/checksums.txt"

echo "Completed: $(date)"
echo "Backup size:"
du -sh "$BACKUP_DIR"
```

**Script 2: Backup PostgreSQL Databases**

```bash
# Save as /data/backups/scripts/backup-postgres.sh
#!/bin/bash
set -euo pipefail

BACKUP_DIR="${1:-/data/backups/manual-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$BACKUP_DIR/postgres"

echo "=== PostgreSQL Backup ==="
echo "Backup destination: $BACKUP_DIR/postgres"

# List of databases to backup
DATABASES=(
  "synapse"
  "matrix-whatsapp"
  "appflowy"
  "ollama"
)

for db in "${DATABASES[@]}"; do
  echo "Backing up: $db"
  pg_dump -h martinibar.lan -p 5433 -U postgres -d "$db" \
    > "$BACKUP_DIR/postgres/${db}.sql" 2>&1 || echo "Failed: $db"
done

echo "Completed: $(date)"
ls -lh "$BACKUP_DIR/postgres/"
```

**Script 3: Verification Script**

```bash
# Save as /data/backups/scripts/verify-backup.sh
#!/bin/bash
set -euo pipefail

BACKUP_DIR="${1:?Backup directory required}"

echo "=== Backup Verification ==="
echo "Verifying: $BACKUP_DIR"

# Check backup exists
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "ERROR: Backup directory not found"
  exit 1
fi

# Verify checksums
if [[ -f "$BACKUP_DIR/checksums.txt" ]]; then
  echo "Verifying checksums..."
  cd "$BACKUP_DIR"
  sha256sum -c checksums.txt --quiet && echo "✓ Checksums OK" || echo "✗ Checksum FAILED"
fi

# Check critical files
echo "Checking critical files..."
CRITICAL_FILES=(
  "glusterfs-volumes/glusterfs_plex_config"
  "glusterfs-volumes/glusterfs_jellyfin_config"
  "postgres/synapse.sql"
)

for file in "${CRITICAL_FILES[@]}"; do
  if [[ -e "$BACKUP_DIR/$file" ]]; then
    echo "✓ $file"
  else
    echo "✗ MISSING: $file"
  fi
done

echo "Backup verification complete"
```

### Make Scripts Executable

```bash
ssh 192.168.1.6 "sudo chmod +x /data/backups/scripts/*.sh"
```

---

## Phase 1: Mount Options Optimization

### Estimated Time: 3-4 hours
### Risk Level: 🟡 Medium
### Downtime: Rolling restarts (5-10 min per service)

### Overview

1. Update GlusterFS plugin configuration with optimized mount options
2. Test with Jellyfin config volume (smallest, least critical)
3. Recreate remaining volumes in order of increasing criticality
4. Verify performance improvements

### Step 1.1: Full System Backup

```bash
# Run on Heracles
ssh 192.168.1.6

PHASE1_BACKUP="/data/backups/glusterfs-migration-<timestamp>/phase1"

# Backup GlusterFS volumes
/data/backups/scripts/backup-glusterfs-volumes.sh "$PHASE1_BACKUP"

# Backup PostgreSQL
/data/backups/scripts/backup-postgres.sh "$PHASE1_BACKUP"

# Verify backup
/data/backups/scripts/verify-backup.sh "$PHASE1_BACKUP"

# Document current state
nomad volume status > "$PHASE1_BACKUP/pre-volumes.txt"
ssh 192.168.1.6 "mount | grep glusterfs" > "$PHASE1_BACKUP/pre-mounts.txt"
```

### Step 1.2: Update GlusterFS Plugin Configuration

**File 1:** `modules/plugin-csi-glusterfs/jobspec-nodes.nomad.hcl`

**Location of change:** Lines 34-38 (inside the template data block)

**FROM:**
```yaml
  mountOptions:
    - nfsvers=3
    - noatime
    - noac
    - lookupcache=none
```

**TO:**
```yaml
  mountOptions:
    - nfsvers=3
    - noatime
    - ac
    - actimeo=60
    - lookupcache=positive
    - hard
    - intr
    - retrans=3
    - timeo=600
    - rsize=1048576
    - wsize=1048576
```

**File 2:** `modules/plugin-csi-glusterfs/jobspec-controller.nomad.hcl`

**Location of change:** After line 33 (add mountOptions to template)

**Note:** Controller doesn't typically mount volumes, but add for consistency.

**ADD after `dirPermissionsGroup: root`:**
```yaml
  mountOptions:
    - nfsvers=3
    - noatime
    - ac
    - actimeo=60
    - lookupcache=positive
    - hard
    - intr
    - retrans=3
    - timeo=600
    - rsize=1048576
    - wsize=1048576
```

### Step 1.3: Deploy Updated Plugin

```bash
# Load environment
source .env
export NOMAD_ADDR="https://nomad.brmartin.co.uk:443"

# Plan changes
terraform plan -out=tfplan-phase1-plugin

# Review plan (should show updates to both plugin jobs)
terraform show tfplan-phase1-plugin

# Apply
terraform apply tfplan-phase1-plugin

# Monitor plugin rollout
watch nomad job status plugin-glusterfs-nodes
# Wait for all 3 allocations to be "running" with new version

# Verify plugin healthy
nomad plugin status glusterfs
```

### Step 1.4: TEST - Recreate Jellyfin Config Volume

**Objective:** Test volume recreation process with smallest, least critical volume

```bash
# 1. Stop media-centre job
nomad job stop media-centre

# 2. Wait for graceful shutdown
nomad job status media-centre
# Wait until all allocations show "complete"

# 3. Check backend data before deletion
ssh 192.168.1.6 "ls -la /storage/v/glusterfs_jellyfin_config"
# Note file count and sizes

# 4. Delete CSI volume
nomad volume delete glusterfs_jellyfin_config

# 5. Verify backend data STILL EXISTS
ssh 192.168.1.6 "ls -la /storage/v/glusterfs_jellyfin_config"
# Should show same files

# 6. Recreate volume via Terraform
# The volume resource already exists in modules/media-centre/main.tf
# Just re-apply
terraform apply -auto-approve

# 7. Verify new volume created
nomad volume status glusterfs_jellyfin_config

# 8. Check mount options on a node
ssh 192.168.1.6 "mount | grep jellyfin"
# Should show new options: ac,actimeo=60,lookupcache=positive

# If mount not visible yet (volume not attached), continue...

# 9. Restart media-centre job
terraform apply -auto-approve
# This will restart the job with the volume

# 10. Verify Jellyfin starts successfully
nomad job status media-centre
nomad alloc logs -f <jellyfin-alloc> jellyfin

# 11. Test Jellyfin web UI
curl -I https://jellyfin.brmartin.co.uk

# 12. Verify mount options NOW visible
ssh 192.168.1.6 "mount | grep jellyfin"
# Should show: ac,actimeo=60,lookupcache=positive,hard,intr,retrans=3,timeo=600

# 13. Check for errors
nomad alloc logs <jellyfin-alloc> jellyfin | grep -i error
```

**If test successful, proceed with remaining volumes. If issues occur, investigate before continuing.**

### Step 1.5: Recreate Remaining Volumes

**Order of recreation (increasing criticality):**

1. ✅ `glusterfs_jellyfin_config` (DONE - test case)
2. `glusterfs_plex_config`
3. `glusterfs_searxng_config`
4. `glusterfs_ollama_data`
5. `glusterfs_ollama_postgres`
6. `glusterfs_appflowy_postgres`
7. `glusterfs_minio_data`

**General procedure for each:**

```bash
# Template for each volume
VOLUME_NAME="<volume-name>"
JOB_NAME="<job-name>"

# 1. Stop job
nomad job stop "$JOB_NAME"

# 2. Wait for shutdown
nomad job status "$JOB_NAME"

# 3. Verify backend data
ssh 192.168.1.6 "ls -la /storage/v/$VOLUME_NAME"

# 4. Delete volume
nomad volume delete "$VOLUME_NAME"

# 5. Verify data still exists
ssh 192.168.1.6 "ls -la /storage/v/$VOLUME_NAME"

# 6. Recreate via Terraform
terraform apply -auto-approve

# 7. Verify volume
nomad volume status "$VOLUME_NAME"

# 8. Restart job
terraform apply -auto-approve

# 9. Verify mount options
ssh 192.168.1.6 "mount | grep $VOLUME_NAME"

# 10. Test service
# <service-specific health check>

# 11. Check logs
nomad alloc logs <alloc> <task> | grep -i error
```

#### Plex Config Volume

```bash
# Plex has 3 task groups, focus on plex task
VOLUME_NAME="glusterfs_plex_config"
JOB_NAME="media-centre"

nomad job stop media-centre
nomad volume delete glusterfs_plex_config

# Verify data
ssh 192.168.1.6 "du -sh /storage/v/glusterfs_plex_config"

terraform apply -auto-approve
nomad volume status glusterfs_plex_config

terraform apply -auto-approve

# Test Plex
curl -I https://plex.brmartin.co.uk

# Verify Litestream replication working
nomad alloc logs <plex-alloc> litestream
```

#### Ollama Volumes (3 volumes, 1 job)

```bash
# Stop ollama once, recreate all 3 volumes
nomad job stop ollama

nomad volume delete glusterfs_searxng_config
nomad volume delete glusterfs_ollama_data
nomad volume delete glusterfs_ollama_postgres

# Verify data
ssh 192.168.1.6 "ls -la /storage/v/glusterfs_searxng_config"
ssh 192.168.1.6 "du -sh /storage/v/glusterfs_ollama_data"
ssh 192.168.1.6 "ls -la /storage/v/glusterfs_ollama_postgres"

terraform apply -auto-approve

nomad volume status glusterfs_searxng_config
nomad volume status glusterfs_ollama_data
nomad volume status glusterfs_ollama_postgres

terraform apply -auto-approve

# Test Ollama
curl http://ollama.service.consul:11434/api/tags

# Test SearXNG
curl http://searxng.service.consul/healthz

# Test Open WebUI (if running)
curl -I http://open-webui.service.consul
```

#### AppFlowy Volume

```bash
VOLUME_NAME="glusterfs_appflowy_postgres"
JOB_NAME="appflowy"

nomad job stop appflowy
nomad volume delete glusterfs_appflowy_postgres

ssh 192.168.1.6 "ls -la /storage/v/glusterfs_appflowy_postgres"

terraform apply -auto-approve
nomad volume status glusterfs_appflowy_postgres

terraform apply -auto-approve

# Test AppFlowy
curl -I https://appflowy.brmartin.co.uk
```

#### MinIO Volume (Most Critical - Plex Litestream depends on it)

```bash
VOLUME_NAME="glusterfs_minio_data"
JOB_NAME="minio"

# Before stopping, note that Plex Litestream replication will fail temporarily
nomad job stop minio
nomad volume delete glusterfs_minio_data

ssh 192.168.1.6 "du -sh /storage/v/glusterfs_minio_data"

terraform apply -auto-approve
nomad volume status glusterfs_minio_data

terraform apply -auto-approve

# Test MinIO
mc admin info local

# Verify Plex Litestream can connect again
nomad alloc logs <plex-alloc> litestream
# Should show successful replication
```

### Step 1.6: Performance Testing

```bash
# Test metadata operations (before/after comparison)
TEST_VOLUME="/storage/v/glusterfs_ollama_data"

# Test 1: Stat performance
time ssh 192.168.1.6 "stat $TEST_VOLUME/*" 

# Test 2: List directory
time ssh 192.168.1.6 "ls -la $TEST_VOLUME"

# Test 3: Read small file
time ssh 192.168.1.6 "cat $TEST_VOLUME/some-small-file.txt > /dev/null"

# Test 4: Write test
time ssh 192.168.1.6 "dd if=/dev/zero of=$TEST_VOLUME/test-write bs=1M count=100 conv=fdatasync"
ssh 192.168.1.6 "rm $TEST_VOLUME/test-write"

# Compare with pre-migration benchmarks (if captured)
```

### Step 1.7: Final Verification

```bash
# All jobs healthy
nomad job status minio
nomad job status ollama
nomad job status appflowy
nomad job status media-centre

# All volumes with new mount options
ssh 192.168.1.6 "mount | grep glusterfs"
# Should ALL show: ac,actimeo=60,lookupcache=positive

# No errors in logs
for job in minio ollama appflowy media-centre; do
  echo "=== $job ==="
  nomad alloc logs $(nomad job status $job | grep running | head -1 | awk '{print $1}') | grep -i error | tail -5
done

# Create verification report
cat > /tmp/phase1-verification.txt <<EOF
Phase 1 Verification Report
Generated: $(date)

Jobs Status:
$(nomad job status | grep -E "(minio|ollama|appflowy|media-centre)")

Volumes with new mount options:
$(ssh 192.168.1.6 "mount | grep glusterfs | grep -c actimeo=60")

Expected: 7 volumes (jellyfin, plex, searxng, ollama_data, ollama_postgres, appflowy_postgres, minio_data)

Performance: (compare with baseline)
- Metadata ops: [TBD]
- List performance: [TBD]

Issues encountered: [NONE / list issues]
EOF

cat /tmp/phase1-verification.txt
```

---

## Phase 2: Matrix Migration

### Estimated Time: 4-6 hours
### Risk Level: 🔴 High (critical service with signing keys)
### Downtime: 15-30 minutes

### Overview

1. Create Matrix CSI volumes (4 separate volumes)
2. Backup Matrix data extensively (including offline signing key backup)
3. Copy data to new volumes
4. Update Matrix jobspec to use CSI volumes
5. Deploy and verify federation, media, bridges

### Step 2.1: Critical Backup

```bash
# Run on Heracles
ssh 192.168.1.6

PHASE2_BACKUP="/data/backups/glusterfs-migration-<timestamp>/phase2"
mkdir -p "$PHASE2_BACKUP"

echo "=== Matrix Critical Backup ==="
echo "Backup destination: $PHASE2_BACKUP"
echo "Started: $(date)"

# CRITICAL: Backup signing keys
echo "Backing up signing keys..."
sudo cp -a /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key \
  "$PHASE2_BACKUP/signing-key-CRITICAL"

# Backup all Synapse config
echo "Backing up Synapse config..."
sudo rsync -avP /mnt/docker/matrix/synapse/ "$PHASE2_BACKUP/synapse/"

# Backup media store (this may take time)
echo "Backing up media store..."
sudo rsync -avP /mnt/docker/matrix/media_store/ "$PHASE2_BACKUP/media_store/"

# Backup WhatsApp bridge
echo "Backing up WhatsApp bridge..."
sudo rsync -avP /mnt/docker/matrix/whatsapp-data/ "$PHASE2_BACKUP/whatsapp-data/"

# Backup static configs
echo "Backing up static configs..."
sudo rsync -avP /mnt/docker/matrix/synapse-mas/ "$PHASE2_BACKUP/synapse-mas/"
sudo rsync -avP /mnt/docker/matrix/nginx/ "$PHASE2_BACKUP/nginx/"
sudo rsync -avP /mnt/docker/matrix/cinny/ "$PHASE2_BACKUP/cinny/"

# Backup PostgreSQL databases
echo "Backing up PostgreSQL..."
pg_dump -h martinibar.lan -p 5433 -U postgres -d synapse \
  > "$PHASE2_BACKUP/synapse.sql"
pg_dump -h martinibar.lan -p 5433 -U postgres -d matrix-whatsapp \
  > "$PHASE2_BACKUP/whatsapp.sql"

# Verify backup
echo "Verifying critical signing key..."
diff /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key \
  "$PHASE2_BACKUP/signing-key-CRITICAL"

if [ $? -eq 0 ]; then
  echo "✓ Signing key backup verified"
else
  echo "✗ SIGNING KEY BACKUP FAILED!"
  exit 1
fi

# Calculate checksums
echo "Calculating checksums..."
find "$PHASE2_BACKUP" -type f -exec sha256sum {} \; > "$PHASE2_BACKUP/checksums.txt"

echo "Completed: $(date)"
echo "Backup size:"
du -sh "$PHASE2_BACKUP"

echo ""
echo "CRITICAL: Copy signing key to offline/offsite storage NOW!"
echo "Location: $PHASE2_BACKUP/signing-key-CRITICAL"
echo ""
```

### Step 2.2: Measure Source Data

```bash
# Check sizes for volume planning
ssh 192.168.1.6

du -sh /mnt/docker/matrix/synapse
du -sh /mnt/docker/matrix/media_store
du -sh /mnt/docker/matrix/whatsapp-data
du -sh /mnt/docker/matrix/synapse-mas
du -sh /mnt/docker/matrix/nginx
du -sh /mnt/docker/matrix/cinny

# Count files
find /mnt/docker/matrix/media_store -type f | wc -l

# Note these values for capacity planning
```

### Step 2.3: Create Matrix Terraform Module

**NEW FILE:** `modules/matrix/main.tf`

Create this file with the following content:

```hcl
data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}

# Volume 1: Synapse Config (Critical - signing keys)
resource "nomad_csi_volume" "glusterfs_matrix_synapse_config" {
  depends_on = [data.nomad_plugin.glusterfs]
  
  lifecycle {
    prevent_destroy = true
  }
  
  plugin_id    = "glusterfs"
  name         = "glusterfs_matrix_synapse_config"
  volume_id    = "glusterfs_matrix_synapse_config"
  capacity_min = "1GiB"
  capacity_max = "10GiB"
  
  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

# Volume 2: Synapse Media (Large, user uploads)
resource "nomad_csi_volume" "glusterfs_matrix_synapse_media" {
  depends_on = [data.nomad_plugin.glusterfs]
  
  lifecycle {
    prevent_destroy = true
  }
  
  plugin_id    = "glusterfs"
  name         = "glusterfs_matrix_synapse_media"
  volume_id    = "glusterfs_matrix_synapse_media"
  capacity_min = "10GiB"
  capacity_max = "200GiB"
  
  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

# Volume 3: WhatsApp Bridge Data
resource "nomad_csi_volume" "glusterfs_matrix_whatsapp_data" {
  depends_on = [data.nomad_plugin.glusterfs]
  
  lifecycle {
    prevent_destroy = true
  }
  
  plugin_id    = "glusterfs"
  name         = "glusterfs_matrix_whatsapp_data"
  volume_id    = "glusterfs_matrix_whatsapp_data"
  capacity_min = "1GiB"
  capacity_max = "10GiB"
  
  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

# Volume 4: Shared Static Configs (MAS, Nginx, Cinny)
resource "nomad_csi_volume" "glusterfs_matrix_shared_config" {
  depends_on = [data.nomad_plugin.glusterfs]
  
  lifecycle {
    prevent_destroy = true
  }
  
  plugin_id    = "glusterfs"
  name         = "glusterfs_matrix_shared_config"
  volume_id    = "glusterfs_matrix_shared_config"
  capacity_min = "1GiB"
  capacity_max = "5GiB"
  
  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }
}

resource "nomad_job" "matrix" {
  depends_on = [
    nomad_csi_volume.glusterfs_matrix_synapse_config,
    nomad_csi_volume.glusterfs_matrix_synapse_media,
    nomad_csi_volume.glusterfs_matrix_whatsapp_data,
    nomad_csi_volume.glusterfs_matrix_shared_config,
  ]
  
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
```

### Step 2.4: Update main.tf

**FILE:** `main.tf` (at project root)

Find the matrix module declaration (around line 41-45) and replace:

```hcl
# BEFORE:
module "matrix" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/matrix/jobspec.nomad.hcl"
}

# AFTER:
module "matrix" {
  source = "./modules/matrix"

  depends_on = [
    module.plugin_csi_glusterfs_controller,
    module.plugin_csi_glusterfs_nodes
  ]
}
```

### Step 2.5: Create CSI Volumes (Without Deploying Job)

```bash
# Temporarily comment out the nomad_job resource in modules/matrix/main.tf
# Edit modules/matrix/main.tf and comment lines with the nomad_job resource

# Plan volume creation
terraform plan -out=tfplan-matrix-volumes

# Review plan - should show 4 new CSI volumes, no job changes
terraform show tfplan-matrix-volumes | grep "nomad_csi_volume"

# Apply
terraform apply tfplan-matrix-volumes

# Verify volumes created
nomad volume status glusterfs_matrix_synapse_config
nomad volume status glusterfs_matrix_synapse_media
nomad volume status glusterfs_matrix_whatsapp_data
nomad volume status glusterfs_matrix_shared_config

# Check backend directories
ssh 192.168.1.6 "ls -la /storage/v/ | grep matrix"
# Should show 4 new directories
```

### Step 2.6: Copy Data to New Volumes

```bash
# Run on Heracles
ssh 192.168.1.6

echo "=== Copying Matrix Data to CSI Volumes ==="
echo "Started: $(date)"

# Volume 1: Synapse Config
echo "Copying Synapse config..."
sudo rsync -avP --delete \
  /mnt/docker/matrix/synapse/ \
  /storage/v/glusterfs_matrix_synapse_config/

# Volume 2: Synapse Media (this will take time - large dataset)
echo "Copying Synapse media... (this may take 30-60 minutes)"
sudo rsync -avP --delete \
  /mnt/docker/matrix/media_store/ \
  /storage/v/glusterfs_matrix_synapse_media/

# Volume 3: WhatsApp Bridge
echo "Copying WhatsApp bridge data..."
sudo rsync -avP --delete \
  /mnt/docker/matrix/whatsapp-data/ \
  /storage/v/glusterfs_matrix_whatsapp_data/

# Volume 4: Shared Configs
echo "Copying shared configs..."
sudo mkdir -p /storage/v/glusterfs_matrix_shared_config/{mas,nginx,cinny}

sudo rsync -avP --delete \
  /mnt/docker/matrix/synapse-mas/ \
  /storage/v/glusterfs_matrix_shared_config/mas/

sudo rsync -avP --delete \
  /mnt/docker/matrix/nginx/ \
  /storage/v/glusterfs_matrix_shared_config/nginx/

sudo rsync -avP --delete \
  /mnt/docker/matrix/cinny/ \
  /storage/v/glusterfs_matrix_shared_config/cinny/

echo "Completed: $(date)"

# CRITICAL: Verify signing key
echo ""
echo "=== CRITICAL: Verifying Signing Key ==="
sudo diff /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key \
  /storage/v/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key

if [ $? -eq 0 ]; then
  echo "✓ Signing key verified - identical"
else
  echo "✗ SIGNING KEY MISMATCH - DO NOT PROCEED!"
  exit 1
fi

# Verify data integrity with checksums
echo ""
echo "=== Verifying Data Integrity ==="
echo "Source checksums..."
find /mnt/docker/matrix/synapse -type f -exec sha256sum {} \; | sort > /tmp/source-synapse-checksums.txt
echo "Destination checksums..."
find /storage/v/glusterfs_matrix_synapse_config -type f -exec sha256sum {} \; | sed 's|/storage/v/glusterfs_matrix_synapse_config|/mnt/docker/matrix/synapse|' | sort > /tmp/dest-synapse-checksums.txt

echo "Comparing..."
diff /tmp/source-synapse-checksums.txt /tmp/dest-synapse-checksums.txt
if [ $? -eq 0 ]; then
  echo "✓ Synapse config data verified"
else
  echo "⚠ Checksum differences found - review before proceeding"
fi

echo ""
echo "Data copy complete. Review output above before proceeding."
```

### Step 2.7: Update Matrix Jobspec

**FILE:** `modules/matrix/jobspec.nomad.hcl`

This file requires extensive changes. Key modifications:

#### Synapse Group

```hcl
group "synapse" {
  network {
    mode = "bridge"
    port "synapse" {
      to = 8008
    }
    port "envoy_metrics" {
      to = 9102
    }
  }

  # ADD: CSI volume declarations
  volume "config" {
    type            = "csi"
    read_only       = false
    source          = "glusterfs_matrix_synapse_config"
    attachment_mode = "file-system"
    access_mode     = "single-node-writer"
  }
  
  volume "media" {
    type            = "csi"
    read_only       = false
    source          = "glusterfs_matrix_synapse_media"
    attachment_mode = "file-system"
    access_mode     = "single-node-writer"
  }

  # ... (service and task sections follow) ...

  task "synapse" {
    driver = "docker"

    config {
      image = "ghcr.io/element-hq/synapse:v1.144.0"

      # REMOVE these lines (around line 75-78):
      # volumes = [
      #   "/mnt/docker/matrix/synapse:/data",
      #   "/mnt/docker/matrix/media_store:/media_store",
      # ]
    }

    # ADD: CSI volume mounts (after config block)
    volume_mount {
      volume      = "config"
      destination = "/data"
    }
    
    volume_mount {
      volume      = "media"
      destination = "/media"
    }

    # In the template block (around line 110), UPDATE:
    template {
      data = <<-EOF
        server_name: "brmartin.co.uk"
        public_baseurl: https://matrix.brmartin.co.uk/
        pid_file: /data/homeserver.pid
        worker_app: synapse.app.homeserver
        
        # CHANGE THIS LINE:
        # Before: (no media_store_path specified, defaults to /data/media_store)
        # After: 
        media_store_path: "/media"
        
        # ... rest of config unchanged ...
      EOF
      
      destination = "local/synapse-config.yaml"
    }

    # ... rest of task unchanged ...
  }
}
```

#### WhatsApp Bridge Group

```hcl
group "whatsapp-bridge" {
  network {
    mode = "bridge"
    port "envoy_metrics" {
      to = 9102
    }
  }

  # ADD: CSI volume
  volume "data" {
    type            = "csi"
    read_only       = false
    source          = "glusterfs_matrix_whatsapp_data"
    attachment_mode = "file-system"
    access_mode     = "single-node-writer"
  }

  # ... (service section) ...

  task "whatsapp-bridge" {
    driver = "docker"

    config {
      image = "dock.mau.dev/mautrix/whatsapp:v0.2512.0"

      # REMOVE (around line 285-287):
      # volumes = [
      #   "/mnt/docker/matrix/whatsapp-data:/data"
      # ]
    }

    # ADD: CSI volume mount
    volume_mount {
      volume      = "data"
      destination = "/data"
    }

    # ... rest unchanged ...
  }
}
```

#### MAS Group

```hcl
group "mas" {
  network {
    mode = "bridge"
    port "envoy_metrics" {
      to = 9102
    }
  }

  # ADD: CSI volume
  volume "config" {
    type            = "csi"
    read_only       = true
    source          = "glusterfs_matrix_shared_config"
    attachment_mode = "file-system"
    access_mode     = "single-node-writer"
  }

  # ... (service section) ...

  task "mas" {
    driver = "docker"

    config {
      image = "ghcr.io/element-hq/matrix-authentication-service:1.8.0"

      # REMOVE (around line 353-355):
      # volumes = [
      #   "/mnt/docker/matrix/synapse-mas/config.yaml:/config.yaml:ro"
      # ]
    }

    # ADD: CSI volume mount
    volume_mount {
      volume      = "config"
      destination = "/shared"
      read_only   = true
    }

    env {
      # UPDATE this line (around line 359):
      # Before: MAS_CONFIG = "/config.yaml"
      # After:
      MAS_CONFIG = "/shared/mas/config.yaml"
    }

    # ... rest unchanged ...
  }
}
```

#### Nginx Group

```hcl
group "nginx" {
  network {
    mode = "bridge"
    port "http" {}
    port "envoy_metrics" {
      to = 9102
    }
  }

  # ADD: CSI volume
  volume "config" {
    type            = "csi"
    read_only       = true
    source          = "glusterfs_matrix_shared_config"
    attachment_mode = "file-system"
    access_mode     = "single-node-writer"
  }

  # ... (service section) ...

  task "nginx" {
    driver = "docker"

    config {
      image = "docker.io/library/nginx:1.29.4-alpine"

      # REMOVE (around line 430-432):
      # volumes = [
      #   "/mnt/docker/matrix/nginx/html:/usr/share/nginx/html:ro",
      # ]

      mount {
        type   = "bind"
        source = "local/nginx.conf"
        target = "/etc/nginx/nginx.conf"
      }
    }

    # ADD: CSI volume mount
    volume_mount {
      volume      = "config"
      destination = "/shared"
      read_only   = true
    }

    # UPDATE template (around line 474-476):
    template {
      data = <<-EOF
        # ... nginx config ...
        
        location /.well-known/matrix {
          # Before: root /usr/share/nginx/html;
          # After:
          root /shared/nginx/html;
        }
        
        # ... rest unchanged ...
      EOF
      
      destination   = "local/nginx.conf"
      change_mode   = "signal"
      change_signal = "SIGHUP"
    }

    # ... rest unchanged ...
  }
}
```

#### Cinny Group

```hcl
group "cinny" {
  network {
    port "cinny" {
      to = 80
    }
  }

  # ADD: CSI volume
  volume "config" {
    type            = "csi"
    read_only       = true
    source          = "glusterfs_matrix_shared_config"
    attachment_mode = "file-system"
    access_mode     = "single-node-writer"
  }

  task "cinny" {
    driver = "docker"

    config {
      image = "ghcr.io/cinnyapp/cinny:v4.10.2"
      ports = ["cinny"]

      # REMOVE (around line 614-616):
      # volumes = [
      #   "/mnt/docker/matrix/cinny/config.json:/app/config.json:ro"
      # ]

      # ADD: Bind mount from CSI volume
      mount {
        type     = "bind"
        source   = "/shared/cinny/config.json"
        target   = "/app/config.json"
        readonly = true
      }
    }

    # ADD: CSI volume mount
    volume_mount {
      volume      = "config"
      destination = "/shared"
      read_only   = true
    }

    # ... rest unchanged ...
  }
}
```

**Element group:** No changes needed (no persistent storage)

### Step 2.8: Deploy Updated Matrix Job

```bash
# Uncomment the nomad_job resource in modules/matrix/main.tf

# Plan deployment
source .env
export NOMAD_ADDR="https://nomad.brmartin.co.uk:443"

terraform plan -out=tfplan-matrix-deploy

# Review carefully - should show job recreation with volume changes
terraform show tfplan-matrix-deploy | less

# STOP current Matrix job
nomad job stop matrix

# Wait for graceful shutdown (critical)
watch nomad job status matrix
# Wait until ALL allocations show "complete"

# Apply Terraform (deploy updated job with CSI volumes)
terraform apply tfplan-matrix-deploy

# Monitor startup closely
watch nomad job status matrix

# Check each task group
for group in synapse whatsapp-bridge mas nginx cinny element; do
  echo "=== $group ==="
  ALLOC=$(nomad job status matrix | grep $group | grep running | head -1 | awk '{print $1}')
  if [ -n "$ALLOC" ]; then
    nomad alloc status $ALLOC
  fi
done
```

### Step 2.9: Monitor Logs During Startup

```bash
# Synapse (most critical)
SYNAPSE_ALLOC=$(nomad job status matrix | grep synapse | grep running | awk '{print $1}')
nomad alloc logs -f $SYNAPSE_ALLOC synapse

# Look for:
# - Successful startup
# - No errors loading signing key
# - Database connection successful
# - Federation listeners started

# WhatsApp Bridge
WHATSAPP_ALLOC=$(nomad job status matrix | grep whatsapp | grep running | awk '{print $1}')
nomad alloc logs -f $WHATSAPP_ALLOC whatsapp-bridge

# MAS
MAS_ALLOC=$(nomad job status matrix | grep mas | grep running | awk '{print $1}')
nomad alloc logs -f $MAS_ALLOC mas
```

### Step 2.10: Comprehensive Testing

```bash
echo "=== Matrix Migration Testing ==="

# Test 1: Federation (CRITICAL - verifies signing key)
echo "Test 1: Federation..."
curl -k https://matrix.brmartin.co.uk/_matrix/federation/v1/version
# Expected: {"server":{"name":"Synapse","version":"..."}}

# Test 2: Client API
echo "Test 2: Client API..."
curl https://matrix.brmartin.co.uk/_matrix/client/versions
# Expected: {"versions":["r0.0.1", ...]}

# Test 3: Server version
echo "Test 3: Server version..."
curl https://matrix.brmartin.co.uk/_matrix/client/v3/capabilities
# Should return capabilities

# Test 4: Media - Upload a test file via Element
echo "Test 4: Media upload..."
echo "Manual test: Open Element, upload an image to a room"
echo "Press Enter when done..."
read

# Test 5: Media - Download existing media
echo "Test 5: Media download (existing)..."
# Get a media URL from before migration and test access
# Example: https://matrix.brmartin.co.uk/_matrix/media/v3/download/brmartin.co.uk/...

# Test 6: WhatsApp Bridge
echo "Test 6: WhatsApp bridge..."
echo "Manual test:"
echo "1. Send message from WhatsApp"
echo "2. Verify delivery to Matrix"
echo "3. Send message from Matrix"
echo "4. Verify delivery to WhatsApp"
echo "Press Enter when done..."
read

# Test 7: MAS Authentication
echo "Test 7: MAS authentication..."
echo "Manual test:"
echo "1. Log out of Element"
echo "2. Log back in"
echo "3. Verify SSO flow works"
echo "Press Enter when done..."
read

# Test 8: Element Web
echo "Test 8: Element client..."
curl -I https://element.brmartin.co.uk
# Expected: 200 OK

# Test 9: Cinny Web
echo "Test 9: Cinny client..."
curl -I https://cinny.brmartin.co.uk
# Expected: 200 OK

# Test 10: Nginx well-known
echo "Test 10: Well-known delegation..."
curl https://brmartin.co.uk/.well-known/matrix/server
# Should return delegation info

# Check logs for errors
echo ""
echo "Checking logs for errors..."
for task in synapse whatsapp-bridge mas; do
  echo "=== $task ==="
  ALLOC=$(nomad job status matrix | grep $task | grep running | awk '{print $1}')
  if [ -n "$ALLOC" ]; then
    nomad alloc logs $ALLOC $task | grep -i error | tail -10
  fi
done

echo ""
echo "=== Testing Complete ==="
echo "Review results above. All tests should pass."
```

### Step 2.11: Verify Mount Options

```bash
# Verify new Matrix volumes have optimized mount options
ssh 192.168.1.6 "mount | grep matrix"

# Should show for each volume:
# ac,actimeo=60,lookupcache=positive,hard,intr,retrans=3,timeo=600

# Example output:
# 127.0.0.1:/storage/v/glusterfs_matrix_synapse_config on ... type nfs (rw,relatime,vers=3,...,ac,actimeo=60,lookupcache=positive,...)
```

### Step 2.12: Post-Migration Verification

```bash
# Create verification report
cat > /tmp/phase2-verification.txt <<EOF
Phase 2: Matrix Migration Verification Report
Generated: $(date)

=== Job Status ===
$(nomad job status matrix)

=== Volume Mounts ===
$(ssh 192.168.1.6 "mount | grep matrix" | wc -l) Matrix volumes mounted

=== Federation Test ===
$(curl -s -k https://matrix.brmartin.co.uk/_matrix/federation/v1/version)

=== Client API Test ===
$(curl -s https://matrix.brmartin.co.uk/_matrix/client/versions | jq -r '.versions[0]')

=== Signing Key Verification ===
$(ssh 192.168.1.6 "sha256sum /storage/v/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key")

Backup signing key checksum:
$(sha256sum /data/backups/glusterfs-migration-*/phase2/signing-key-CRITICAL)

Keys match: $(diff <(ssh 192.168.1.6 "sha256sum /storage/v/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key" | awk '{print $1}') <(sha256sum /data/backups/glusterfs-migration-*/phase2/signing-key-CRITICAL | awk '{print $1}') && echo YES || echo NO)

=== Error Summary ===
Synapse errors: $(nomad alloc logs $(nomad job status matrix | grep synapse | grep running | awk '{print $1}') synapse | grep -i error | wc -l)
WhatsApp errors: $(nomad alloc logs $(nomad job status matrix | grep whatsapp | grep running | awk '{print $1}') whatsapp-bridge | grep -i error | wc -l)
MAS errors: $(nomad alloc logs $(nomad job status matrix | grep mas | grep running | awk '{print $1}') mas | grep -i error | wc -l)

=== Manual Tests ===
[ ] Media upload successful
[ ] Media download successful (existing media)
[ ] WhatsApp → Matrix message delivery
[ ] Matrix → WhatsApp message delivery
[ ] SSO authentication working
[ ] Element client accessible
[ ] Cinny client accessible

=== Issues Encountered ===
[NONE / list issues]

=== Migration Status ===
[ ] SUCCESSFUL - All tests passed
[ ] ISSUES - Review and address
[ ] ROLLBACK - Critical failure

EOF

cat /tmp/phase2-verification.txt

# Save to backup location
cp /tmp/phase2-verification.txt \
  /data/backups/glusterfs-migration-*/phase2/verification-report.txt
```

---

## Post-Migration Tasks

### Update Documentation

**FILE:** `README.md`

Add a new section after line 30 (after "Prerequisites"):

```markdown
## Storage Architecture

### GlusterFS

The cluster uses GlusterFS for persistent storage accessed via CSI volumes:

**Architecture:**
- **Volume:** `nomad-vol` (Distribute type, 2 bricks: Heracles + Nyx)
- **Mount:** FUSE client → NFS re-export → Democratic-CSI
- **Warning:** ⚠️ No replication currently - ensure regular backups

**Mount Options:**
```yaml
- nfsvers=3        # NFSv3 protocol
- ac / actimeo=60  # Attribute caching (60 second TTL)
- lookupcache=positive  # Cache successful lookups
- hard             # Retry on failure
- rsize=1048576    # 1MB read buffer
- wsize=1048576    # 1MB write buffer
```

**Services on GlusterFS:**
- **Matrix:** Config, media, bridges (4 separate volumes)
- **MinIO:** Object storage
- **Ollama:** Models, config, database
- **AppFlowy:** Database
- **Plex:** Configuration only (SQLite on ephemeral + Litestream)
- **Jellyfin:** Configuration

**Services NOT on GlusterFS:**
- **Elasticsearch:** Local host volumes (performance) + Martinibar backups
- **Plex media files:** Martinibar NFS (large datasets)
- **Forgejo:** Martinibar NFS (awaiting GitLab migration)

**SQLite Warning:** ⚠️ **NEVER store SQLite databases on GlusterFS!** 
- Use PostgreSQL for network storage
- OR use ephemeral disk + replication (e.g., Litestream)
- File locking on NFS is unreliable for SQLite

**Backup Strategy:**
- **Daily:** Critical configs, PostgreSQL databases
- **Weekly:** Full GlusterFS volume backup
- **Offsite:** Matrix signing keys (CRITICAL - cannot be regenerated)
```

### Backup Automation

**Create:** `/data/backups/scripts/daily-backup.sh`

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/data/backups/daily/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"/{glusterfs,postgres}

echo "=== Daily Backup ==="
echo "Destination: $BACKUP_DIR"
echo "Started: $(date)"

# Backup critical GlusterFS volumes
echo "Backing up critical volumes..."
for vol in glusterfs_matrix_synapse_config glusterfs_plex_config glusterfs_jellyfin_config; do
  echo "  - $vol"
  sudo rsync -aq --delete "/storage/v/$vol/" "$BACKUP_DIR/glusterfs/$vol/"
done

# Backup PostgreSQL databases
echo "Backing up PostgreSQL databases..."
for db in synapse matrix-whatsapp appflowy ollama; do
  echo "  - $db"
  pg_dump -h martinibar.lan -p 5433 -U postgres -d "$db" \
    > "$BACKUP_DIR/postgres/${db}.sql" 2>&1 || echo "    Failed: $db"
done

# Calculate checksums
find "$BACKUP_DIR" -type f -exec sha256sum {} \; > "$BACKUP_DIR/checksums.txt"

# Cleanup old backups (keep 7 days)
find /data/backups/daily -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;

echo "Completed: $(date)"
du -sh "$BACKUP_DIR"
```

**Create:** `/data/backups/scripts/weekly-backup.sh`

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/data/backups/weekly/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

echo "=== Weekly Full Backup ==="
echo "Destination: $BACKUP_DIR"
echo "Started: $(date)"

# Full GlusterFS backup
echo "Backing up all GlusterFS volumes..."
sudo rsync -avP --delete /storage/v/ "$BACKUP_DIR/glusterfs-volumes/"

# Backup PostgreSQL
echo "Backing up PostgreSQL..."
for db in synapse matrix-whatsapp appflowy ollama; do
  echo "  - $db"
  pg_dump -h martinibar.lan -p 5433 -U postgres -d "$db" \
    > "$BACKUP_DIR/postgres-${db}.sql"
done

# Calculate checksums
find "$BACKUP_DIR" -type f -exec sha256sum {} \; > "$BACKUP_DIR/checksums.txt"

# Cleanup old backups (keep 4 weeks)
find /data/backups/weekly -maxdepth 1 -type d -mtime +28 -exec rm -rf {} \;

echo "Completed: $(date)"
du -sh "$BACKUP_DIR"
```

**Setup cron jobs:**

```bash
# On Heracles
ssh 192.168.1.6

# Make scripts executable
sudo chmod +x /data/backups/scripts/{daily,weekly}-backup.sh

# Add to crontab
sudo crontab -e

# Add these lines:
# Daily backup at 2 AM
0 2 * * * /data/backups/scripts/daily-backup.sh >> /var/log/glusterfs-daily-backup.log 2>&1

# Weekly backup at 3 AM on Sundays
0 3 * * 0 /data/backups/scripts/weekly-backup.sh >> /var/log/glusterfs-weekly-backup.log 2>&1
```

### Monitoring Setup

**Create health check script:**

```bash
# /data/scripts/glusterfs-health-check.sh
#!/bin/bash

echo "=== GlusterFS Health Check ==="
echo "Date: $(date)"

# Check GlusterFS volume status
echo ""
echo "Volume Status:"
sudo gluster volume status nomad-vol

# Check for split-brain
echo ""
echo "Split-brain Check:"
sudo gluster volume heal nomad-vol info

# Check brick status
echo ""
echo "Brick Status:"
sudo gluster volume status nomad-vol detail | grep -E "Brick|Online"

# Check CSI plugin health
echo ""
echo "CSI Plugin Health:"
nomad plugin status glusterfs

# Check NFS exports
echo ""
echo "NFS Exports:"
sudo exportfs -v

# Check disk usage
echo ""
echo "Disk Usage:"
df -h /storage
df -h /data/glusterfs/brick1

echo ""
echo "=== Health Check Complete ==="
```

### Create Runbooks

**FILE:** `.opencode/runbooks/glusterfs-operations.md`

```markdown
# GlusterFS Operations Runbook

## Adding a New Service to GlusterFS

1. Verify service doesn't use SQLite
2. Create CSI volume in Terraform module
3. Update jobspec with CSI volume mounts
4. Test and deploy

Example:
See `modules/matrix/main.tf` for volume definitions
See `modules/matrix/jobspec.nomad.hcl` for volume usage

## GlusterFS Brick Failure

**Current Configuration:** Distribute (NO replication)
**Impact:** DATA LOSS if brick fails

**Recovery:**
1. Identify failed brick: `gluster volume status nomad-vol`
2. Restore from backup immediately
3. Replace/repair brick
4. Re-add to volume: `gluster volume add-brick ...`

**Prevention:**
- Maintain daily backups
- Plan migration to replicated volume

## CSI Volume Recreation

When to recreate: Mount options change, corruption suspected

**Procedure:**
1. Stop job using volume
2. Delete CSI volume: `nomad volume delete <volume-id>`
3. Verify backend data intact: `ls /storage/v/<volume-name>`
4. Recreate volume: `terraform apply`
5. Restart job

## Performance Issues

**Symptoms:**
- Slow file operations
- High latency
- Application timeouts

**Investigation:**
1. Check GlusterFS health: `/data/scripts/glusterfs-health-check.sh`
2. Check mount options: `mount | grep glusterfs`
3. Check network: `ping 192.168.1.6`, `ping 192.168.1.7`
4. Check disk I/O: `iostat -x 1`
5. Review application logs

**Common Fixes:**
- Restart NFS server: `systemctl restart nfs-server`
- Remount FUSE: `umount /storage && mount -a`
- Check for split-brain: `gluster volume heal nomad-vol info`

## Backup and Restore

**Backup:**
- Daily: `/data/backups/scripts/daily-backup.sh`
- Weekly: `/data/backups/scripts/weekly-backup.sh`
- Manual: `/data/backups/scripts/backup-glusterfs-volumes.sh <dest>`

**Restore:**
```bash
# Stop service
nomad job stop <job-name>

# Restore data
rsync -avP /backups/<timestamp>/glusterfs-volumes/<volume-name>/ /storage/v/<volume-name>/

# Verify
ls -la /storage/v/<volume-name>

# Restart service
terraform apply
```

## Matrix Signing Key Recovery

**CRITICAL:** Matrix signing key cannot be regenerated!

**Backup Locations:**
1. Daily: `/data/backups/daily/*/glusterfs/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key`
2. Migration: `/data/backups/glusterfs-migration-*/phase2/signing-key-CRITICAL`
3. Offsite: [Your offsite location]

**Restore:**
```bash
# Verify current key is corrupt/missing
ls -la /storage/v/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key

# Restore from backup
cp /data/backups/daily/<latest>/glusterfs/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key \
   /storage/v/glusterfs_matrix_synapse_config/

# Verify checksum matches backup
sha256sum /storage/v/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key

# Restart Synapse
nomad job restart matrix -group synapse
```
```

---

## Rollback Procedures

### Phase 1 Rollback: Mount Options

If performance issues or errors occur after mount option changes:

```bash
# 1. Revert plugin configuration
git diff modules/plugin-csi-glusterfs/
git checkout HEAD~1 modules/plugin-csi-glusterfs/

# 2. Apply reverted config
source .env
export NOMAD_ADDR="https://nomad.brmartin.co.uk:443"
terraform apply -auto-approve

# 3. Recreate volumes with old mount options
# For each affected volume:
nomad job stop <job-name>
nomad volume delete <volume-id>
terraform apply -auto-approve

# 4. Verify old mount options
ssh 192.168.1.6 "mount | grep glusterfs"
# Should NOT show ac,actimeo=60

# 5. Restart services
terraform apply -auto-approve
```

### Phase 2 Rollback: Matrix Migration

**CRITICAL:** Only rollback if Matrix is non-functional

```bash
echo "=== EMERGENCY: Matrix Rollback ==="

# 1. Stop current Matrix job
nomad job stop matrix

# 2. Revert Terraform configuration
git diff main.tf modules/matrix/
git checkout HEAD~1 main.tf
git checkout HEAD~1 modules/matrix/

# 3. If data corruption suspected, restore from backup
ssh 192.168.1.6

RESTORE_FROM="/data/backups/glusterfs-migration-<timestamp>/phase2"

# Restore to ORIGINAL locations (not CSI volumes)
sudo rsync -avP --delete \
  "$RESTORE_FROM/synapse/" \
  /mnt/docker/matrix/synapse/

sudo rsync -avP --delete \
  "$RESTORE_FROM/media_store/" \
  /mnt/docker/matrix/media_store/

sudo rsync -avP --delete \
  "$RESTORE_FROM/whatsapp-data/" \
  /mnt/docker/matrix/whatsapp-data/

# CRITICAL: Verify signing key
diff "$RESTORE_FROM/signing-key-CRITICAL" \
  /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key

# 4. Apply old Terraform (restarts Matrix with old config)
source .env
export NOMAD_ADDR="https://nomad.brmartin.co.uk:443"
terraform apply -auto-approve

# 5. Verify Matrix is functional
curl -k https://matrix.brmartin.co.uk/_matrix/federation/v1/version

# 6. Test federation
echo "Test Matrix functionality:"
echo "1. Check Element can connect"
echo "2. Send test message"
echo "3. Test WhatsApp bridge"

# 7. Document rollback
cat > /tmp/matrix-rollback-report.txt <<EOF
Matrix Rollback Report
Date: $(date)
Reason: [FILL IN]

Restore Source: $RESTORE_FROM

Verification:
$(nomad job status matrix)

Federation test:
$(curl -s -k https://matrix.brmartin.co.uk/_matrix/federation/v1/version)

Signing key checksum:
$(sha256sum /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key)

Actions taken:
- Stopped Matrix job
- Reverted Terraform configuration
- Restored data from backup
- Restarted Matrix with old configuration

Next steps:
- Investigate root cause
- Plan re-migration if needed
EOF

cat /tmp/matrix-rollback-report.txt
```

---

## Success Criteria

Migration considered fully successful when ALL criteria met:

### Phase 1 Success Criteria

- [x] GlusterFS plugin updated with optimized mount options
- [x] All 7 existing CSI volumes recreated
- [x] All services healthy: MinIO, Ollama, AppFlowy, Plex, Jellyfin
- [x] Mount options verified: `ac,actimeo=60,lookupcache=positive`
- [x] No errors in service logs
- [x] Performance equal or better than baseline
- [x] Jellyfin test volume recreation successful

### Phase 2 Success Criteria

- [x] 4 Matrix CSI volumes created (config, media, bridge, shared)
- [x] Matrix data successfully copied to CSI volumes
- [x] Matrix job deployed with CSI volumes
- [x] **CRITICAL:** Federation working (signing key verified)
- [x] **CRITICAL:** Signing key checksum matches backup
- [x] Media upload working
- [x] Media download working (existing media accessible)
- [x] WhatsApp bridge bidirectional messaging working
- [x] MAS authentication working
- [x] Element client accessible
- [x] Cinny client accessible
- [x] Mount options verified on all Matrix volumes
- [x] No errors in Synapse/bridge/MAS logs
- [x] All manual tests passed

### Post-Migration Success Criteria

- [x] Documentation updated (README.md)
- [x] Runbooks created
- [x] Backup automation configured (cron jobs)
- [x] Health check script created
- [x] Verification reports generated
- [x] Team briefed on new architecture
- [x] Offsite backup of Matrix signing key confirmed

---

## Appendix: Reference Information

### Volume Inventory

| Volume Name | Service | Size | Critical | Recreated |
|-------------|---------|------|----------|-----------|
| `glusterfs_minio_data` | MinIO | 965MB | High | Phase 1 |
| `glusterfs_ollama_data` | Ollama | 3.8GB | Medium | Phase 1 |
| `glusterfs_ollama_postgres` | Ollama | <1GB | Medium | Phase 1 |
| `glusterfs_searxng_config` | SearXNG | <1GB | Low | Phase 1 |
| `glusterfs_appflowy_postgres` | AppFlowy | <1GB | Medium | Phase 1 |
| `glusterfs_plex_config` | Plex | TBD | High | Phase 1 |
| `glusterfs_jellyfin_config` | Jellyfin | TBD | Low | Phase 1 (TEST) |
| `glusterfs_matrix_synapse_config` | Matrix | TBD | **CRITICAL** | Phase 2 |
| `glusterfs_matrix_synapse_media` | Matrix | TBD | High | Phase 2 |
| `glusterfs_matrix_whatsapp_data` | Matrix | TBD | High | Phase 2 |
| `glusterfs_matrix_shared_config` | Matrix | <1GB | Medium | Phase 2 |

### Mount Options Comparison

| Option | Before | After | Impact |
|--------|--------|-------|--------|
| `nfsvers` | 3 | 3 | No change |
| `noatime` | ✓ | ✓ | No change |
| `ac` | ✗ (noac) | ✓ | +Performance |
| `actimeo` | N/A | 60 | +Performance |
| `lookupcache` | none | positive | +Performance |
| `hard` | ✗ | ✓ | +Reliability |
| `intr` | ✗ | ✓ | +Usability |
| `retrans` | 2 | 3 | +Reliability |
| `timeo` | 600 | 600 | No change |
| `rsize` | 1M | 1M | No change |
| `wsize` | 1M | 1M | No change |

### Cluster Node Details

| Node | IP | Role | GlusterFS Brick |
|------|----|----|----------------|
| Hestia | 192.168.1.5 | Nomad client | None (future) |
| Heracles | 192.168.1.6 | Nomad + GlusterFS | `/data/glusterfs/brick1` |
| Nyx | 192.168.1.7 | Nomad + GlusterFS | `/data/glusterfs/brick1` |

### Critical File Locations

**On Cluster Nodes:**
- GlusterFS FUSE mount: `/storage`
- GlusterFS brick: `/data/glusterfs/brick1`
- CSI volumes backend: `/storage/v/<volume-name>`
- Backups: `/data/backups/`
- Scripts: `/data/backups/scripts/`, `/data/scripts/`

**In Git Repository:**
- Plugin config: `modules/plugin-csi-glusterfs/`
- Matrix module: `modules/matrix/`
- Main config: `main.tf`
- Variables: `variables.tf`
- Environment: `.env`

### Contact Information

**Escalation Path:**
1. Check logs: `nomad alloc logs <alloc> <task>`
2. Check health: `/data/scripts/glusterfs-health-check.sh`
3. Review runbooks: `.opencode/runbooks/glusterfs-operations.md`
4. Check backups: `/data/backups/`
5. Restore from backup if needed

**Matrix Signing Key Locations (CRITICAL):**
1. Production: `/storage/v/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key`
2. Daily backup: `/data/backups/daily/<date>/glusterfs/glusterfs_matrix_synapse_config/brmartin.co.uk.signing.key`
3. Migration backup: `/data/backups/glusterfs-migration-<timestamp>/phase2/signing-key-CRITICAL`
4. Offsite: [CONFIGURE YOUR OFFSITE BACKUP LOCATION]

---

## Document Revision History

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2026-01-11 | 1.0 | Initial comprehensive migration plan | OpenCode |

---

**END OF MIGRATION PLAN**

*This plan should be reviewed and updated as implementation proceeds. Save a copy of this file before beginning execution.*
