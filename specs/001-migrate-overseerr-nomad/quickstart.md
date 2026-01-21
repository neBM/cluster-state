# Quickstart: Migrate Overseerr to Nomad

## Prerequisites

Before deploying, ensure:

1. **Vault secret exists** at `nomad/default/overseerr`: **DONE**
   - Contains `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY`
   - Credentials have rw access to `overseerr-litestream` bucket

2. **MinIO bucket exists**: `overseerr-litestream` **DONE**

3. **Existing database seeded to litestream** (one-time migration):
   ```bash
   # On Hestia, with docker-compose overseerr stopped
   docker stop overseerr
   
   # Run litestream to seed initial backup
   docker run --rm -v /var/lib/docker/volumes/downloads_config-overseerr/_data/db:/data \
     -e LITESTREAM_ACCESS_KEY_ID="<key>" \
     -e LITESTREAM_SECRET_ACCESS_KEY="<secret>" \
     litestream/litestream:0.5 replicate -exec "sleep 30" \
     /data/db.sqlite3 s3://overseerr-litestream/db?endpoint=http://minio-minio.virtual.consul:9000
   ```

4. **Copy settings.json to GlusterFS** (after terraform creates volume):
   ```bash
   # After volume created, copy settings
   sudo cp /var/lib/docker/volumes/downloads_config-overseerr/_data/settings.json \
     /storage/v/overseerr_config/
   ```

## Deployment

```bash
# Load environment
set -a && source .env && set +a

# Plan (target just overseerr module for faster iteration)
terraform plan -target=module.overseerr \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" \
  -out=tfplan

# Apply
terraform apply tfplan
```

## Verification

1. **Check job status**:
   ```bash
   nomad job status overseerr
   ```

2. **Check allocation logs**:
   ```bash
   # Get allocation ID
   ALLOC=$(nomad job status overseerr | grep running | awk '{print $1}')
   
   # Check restore task
   nomad alloc logs $ALLOC litestream-restore
   
   # Check main task
   nomad alloc logs $ALLOC overseerr
   
   # Check litestream sidecar
   nomad alloc logs $ALLOC litestream
   ```

3. **Verify web access**:
   ```bash
   curl -I https://overseerr.brmartin.co.uk
   # Should return HTTP 200
   ```

4. **Verify litestream replication**:
   ```bash
   mc ls minio/overseerr-litestream/db/
   # Should show generations and WAL segments
   ```

## Rollback

If issues occur:

1. **Stop Nomad job**:
   ```bash
   nomad job stop overseerr
   ```

2. **Restart docker-compose** (if still present):
   ```bash
   ssh 192.168.1.5 "cd /path/to/compose && docker-compose up -d overseerr"
   ```

## Post-Deployment

1. **Access Overseerr UI**: https://overseerr.brmartin.co.uk

2. **Verify integrations** in Settings:
   - Plex: Should show connected (existing config preserved)
   - Sonarr: `http://192.168.1.5:8989` - verify API key works
   - Radarr: `http://192.168.1.5:7878` - verify API key works

3. **Remove docker-compose Overseerr** (after verification):
   ```bash
   ssh 192.168.1.5 "docker rm overseerr"
   # Also remove from docker-compose.yml
   ```

## Troubleshooting

### Job won't start - CSI volume pending
```bash
# Check GlusterFS plugin health
nomad plugin status glusterfs

# Check volume status
nomad volume status glusterfs_overseerr_config
```

### Litestream restore fails
```bash
# Check MinIO connectivity
nomad alloc exec -task overseerr $ALLOC wget -q -O - http://minio-minio.virtual.consul:9000/minio/health/live

# Check bucket exists
mc ls minio/overseerr-litestream/
```

### Service unhealthy in Consul
```bash
# Check health endpoint directly
nomad alloc exec -task overseerr $ALLOC wget -q -O - http://localhost:5055/api/v1/status
```

### Can't reach Sonarr/Radarr
```bash
# Verify transparent proxy works
nomad alloc exec -task overseerr $ALLOC wget -q -O - http://192.168.1.5:8989/api/v1/system/status
# If fails: check Consul Connect transparent proxy config
```
