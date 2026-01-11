# Migration Agents Documentation

## Overview

This document tracks the agent sessions involved in migrating services from NFS (martinibar) storage to GlusterFS storage on the Nomad cluster.

## Migration Phases

### Phase 0: Environment Setup and Pre-flight Checks
**Status:** ✅ Completed

- Environment setup and pre-flight checks
- Created backup directory structure
- Created and tested backup scripts
- Verified cluster health and current state

### Phase 1: GlusterFS Plugin Configuration and Volume Migration
**Status:** ✅ Completed

#### Tasks Completed:
1. **Updated GlusterFS CSI Plugin Configuration** - Enabled NFS attribute caching to fix file locking issues
   - Changed from `noac` to `ac` with `actimeo=60` for better performance
   - Changed from `lookupcache=none` to `lookupcache=positive`
   - Added reliability options: `hard`, `intr`, `retrans=3`, `timeo=600`
   - Optimized transfer sizes: `rsize/wsize=1048576`
   - Files modified:
     - `modules/plugin-csi-glusterfs/jobspec-controller.nomad.hcl`
     - `modules/plugin-csi-glusterfs/jobspec-nodes.nomad.hcl`

2. **Jellyfin Volume Migration**
   - Initial migration failed - deleting the CSI volume also deleted the volume data
   - **Recovery Process:**
     - Located backup data in `/mnt/csi/jellyfin/config/` on Hestia (192.168.1.5)
     - Stopped media-centre job
     - Restored data using: `rsync -av --progress /mnt/csi/jellyfin/config/ /storage/v/glusterfs_jellyfin_config/`
     - Restarted media-centre job successfully
     - Jellyfin task deployed healthy

3. **Plex Volume Migration**
   - Plex was crashing with SQLite database locking errors due to old GlusterFS mount options
   - Old `glusterfs_plex_config` volume was created before plugin updates (without `ac`,`actimeo`,`lookupcache`)
   - **Migration Process:**
     - Backed up 4.7GB of Plex config: `rsync /storage/v/glusterfs_plex_config/ /mnt/csi/plex/`
     - Deleted old volume and recreated with new GlusterFS plugin configuration
     - Restored data: `rsync /mnt/csi/plex/ /storage/v/glusterfs_plex_config/`
     - Removed stale database files from CSI volume (database should be on ephemeral disk via litestream)
     - Added Hestia constraint to Plex task group (requires NVIDIA runtime)
     - Restarted GlusterFS plugin to apply new mount options

4. **Litestream Fixes**
   - Fixed MinIO endpoint from `localhost:9000` to `minio-minio.virtual.consul:9000`
   - Added 60-second wait for connect-proxy to be ready before restore
   - Implemented database fallback copy from CSI volume backup
   - Fixed database file permissions (chmod 666)
   - Litestream successfully connecting to MinIO and writing snapshots
   - **Known Issue:** Plex has database lock conflicts with litestream sidecar (MinIO bucket created but locks prevent Plex access)

5. **Transparent Proxy Migration**
   - Removed explicit upstream definitions (minio-minio) from Plex service
   - All 22 services now using transparent proxy mode exclusively
   - Services connect via DNS (*.virtual.consul) without explicit upstreams
   - Cleaner configuration and improved flexibility

6. **Git Commits (Phase 1):**
   - `d810e0a` - Remove explicit upstreams in favor of transparent proxy
   - `ba77c42` - Add database fallback copy from CSI volume for Plex
   - `76ebcaa` - Fix litestream MinIO endpoint and add connect-proxy wait
   - `9d48447` - Update AGENTS.md with Plex volume migration
   - `dc649b0` - Add Hestia constraint to Plex task group
   - `6fa4a9e` - Enable NFS attribute caching for GlusterFS CSI plugin
   - `0692bd1` - Add AGENTS.md documentation for migration tracking
   - `e1fcc4f` - Clean up workspace and fix Forgejo CSI dependency (previous session)

7. **Git Commits (Phase 2):**
   - `3aee226` - feat(matrix): Create Matrix Terraform module and CSI volumes

#### Lessons Learned:
- ⚠️ **CRITICAL:** Deleting a Nomad CSI volume with `nomad volume delete` also deletes the underlying storage data
- **ALWAYS** backup data from CSI volumes before deletion
- **ALWAYS** verify backup exists and is accessible before proceeding with volume operations
- For future volume migrations, use this process:
  1. Stop the application/job
  2. Backup data from existing volume location
  3. Create new volume
  4. Restore data to new volume location
  5. Restart application/job

### Phase 2: Matrix Migration  
**Status:** 🔄 In Progress (Started 2026-01-11)

#### Completed Tasks:
1. **Created Matrix Terraform Module** ✅
   - Created `modules/matrix/main.tf` with proper CSI volume definitions
   - Created 4 volume definition files: synapse-data, media-store, whatsapp-data, config
   - Integrated module into main Terraform configuration

2. **Created Matrix CSI Volumes** ✅
   - Applied Terraform to create all 4 CSI volumes
   - Volumes created successfully:
     - `glusterfs_matrix_synapse_data` (1-5GB)
     - `glusterfs_matrix_media_store` (10-50GB)
     - `glusterfs_matrix_whatsapp_data` (1-5GB)
     - `glusterfs_matrix_config` (100MB-1GB)
   - Created GlusterFS directories on Hestia with proper permissions

3. **Matrix Data Backup** 🔄 In Progress
   - Created comprehensive backup script (`scripts/backup-matrix.sh`)
   - Backup includes critical signing key with verification
   - Backup location: `/mnt/csi/backups/glusterfs-migration-20260111-105755/phase2/`
   - Media store backup in progress (466MB+ and counting)

#### Remaining Tasks:
- Complete Matrix data backup (waiting for media store)
- Copy data to new GlusterFS volumes
- Update Matrix jobspec to use CSI volumes
- Deploy and verify Matrix federation

### Remaining Volumes to Migrate

The following volumes still need to be migrated from their current storage to GlusterFS:

**From backup inspection (`/mnt/csi/`):**
- `appflowy` - AppFlowy data (already using GlusterFS)
- `elasticsearch` - Elasticsearch data (ELK job currently failing)
- `forgejo` - Forgejo data (using martinibar NFS)
- `forgejo-runner` - Forgejo runner data (using martinibar NFS)
- `home-assistant` - Home Assistant data
- `media` - Media center data
- `minio` - MinIO data (already using GlusterFS)
- `monica` - Monica data
- `n8n` - n8n workflow automation data
- `ollama` - Ollama data (already using GlusterFS)
- `qbittorrent_config` - qBittorrent configuration
- `searxng` - SearXNG data (already using GlusterFS)
- `volts-app` - Volts application data

**Currently Using GlusterFS:**
- ✅ `glusterfs_jellyfin_config` - Jellyfin (migrated and verified)
- ✅ `glusterfs_plex_config` - Plex
- ✅ `glusterfs_appflowy_postgres` - AppFlowy PostgreSQL
- ✅ `glusterfs_minio_data` - MinIO data
- ✅ `glusterfs_ollama_data` - Ollama data
- ✅ `glusterfs_ollama_postgres` - Ollama PostgreSQL
- ✅ `glusterfs_searxng_config` - SearXNG

## Important Locations

### Backup Locations (Hestia - 192.168.1.5)
- CSI volume backups: `/mnt/csi/`
- GlusterFS volumes: `/storage/v/`

### Volume Naming Convention
- GlusterFS volumes: `glusterfs_<service>_<type>`
- Martinibar volumes: `martinibar_prod_<service>_<type>`

## Commands Reference

### Environment Setup
```bash
set -a && source .env && set +a
```

### Terraform Operations
```bash
# Plan changes
set -a && source .env && set +a && terraform plan -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan

# Apply changes
set -a && source .env && set +a && terraform apply -var="nomad_address=https://nomad.brmartin.co.uk:443" tfplan
```

### Data Restoration (for large directories)
```bash
# Use rsync on Hestia to avoid timeouts
ssh 192.168.1.5 "rsync -av --progress /mnt/csi/<service>/ /storage/v/glusterfs_<service>/"
```

### Volume Management
```bash
# Check volume status
nomad volume status <volume_id>

# Delete volume (WARNING: This deletes data!)
nomad volume delete <volume_id>

# List all volumes
nomad volume status
```

## Next Steps

1. ✅ Complete Jellyfin migration and data restoration
2. 🔄 Create AGENTS.md documentation (this file)
3. ⏳ Migrate remaining volumes to GlusterFS
4. ⏳ Create Matrix Terraform module
5. ⏳ Migrate Matrix service
6. ⏳ Post-migration documentation and monitoring

## Agent Session History

### Session 1: Initial Setup and GlusterFS Configuration
- **Date:** 2026-01-11
- **Focus:** GlusterFS plugin configuration and Jellyfin migration
- **Key Achievements:**
  - Updated GlusterFS CSI plugin with proper NFS mount options
  - Successfully migrated and restored Jellyfin data after initial failure
  - Documented critical lessons about CSI volume deletion
  - All media-centre tasks deployed successfully

## Contact & Support

For questions or issues with this migration, refer to:
- Nomad Web UI: https://nomad.brmartin.co.uk:443
- Hestia SSH: 192.168.1.5
