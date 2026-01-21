# Research: Migrate Overseerr to Nomad

**Date**: 2026-01-20
**Branch**: `001-migrate-overseerr-nomad`

## Research Tasks Completed

### 1. Overseerr Container Configuration

**Decision**: Mount `/app/config` for persistent data, use port 5055

**Rationale**: 
- Official Docker documentation specifies `/app/config` as the persistent volume mount
- Port 5055 is the default and only exposed port
- Supports `TZ` environment variable for timezone
- Optional `LOG_LEVEL` and `PORT` environment variables

**Evidence**:
```
/app/config/
├── db/
│   ├── db.sqlite3         # Main database (4.4MB with WAL)
│   ├── db.sqlite3-shm
│   └── db.sqlite3-wal
├── logs/                  # Log files
└── settings.json          # Configuration (6.4KB)
```

### 2. Overseerr Health Check Endpoint

**Decision**: Use `/api/v1/status` for health checks

**Rationale**:
- Returns JSON with version info: `{"version":"1.34.0","commitTag":"$GIT_SHA",...}`
- Returns HTTP 200 when service is healthy
- Quick response, suitable for 5-30s interval checks

**Alternatives Considered**:
- `/` (root) - Returns HTML, heavier response
- TCP check on 5055 - Less reliable, doesn't verify app health

### 3. Sonarr/Radarr Connection Details

**Decision**: Configure via direct IP to Hestia (192.168.1.5)

**Evidence** (from docker ps):
- **Sonarr**: `http://192.168.1.5:8989`
- **Radarr**: `http://192.168.1.5:7878`
- **Plex**: `http://192.168.1.5:32400` (also available via Consul mesh)

**Rationale**: Sonarr/Radarr remain on docker-compose, not in Consul mesh. Direct IP works from any cluster node.

### 4. Litestream Configuration for Overseerr

**Decision**: Follow Plex pattern - single database, MinIO bucket `overseerr-litestream`

**Rationale**:
- Overseerr has one SQLite database: `/app/config/db/db.sqlite3`
- Database is small (~4.5MB) - suitable for frequent replication
- WAL mode already enabled (evidenced by `-wal` and `-shm` files)
- Plex pattern works well for similar workloads

**Configuration Structure**:
```yaml
dbs:
  - path: /alloc/data/db/db.sqlite3
    replicas:
      - name: overseerr
        type: s3
        bucket: overseerr-litestream
        path: db
        endpoint: http://minio-minio.virtual.consul:9000
        access-key-id: <from vault>
        secret-access-key: <from vault>
        force-path-style: true
        sync-interval: 5m
        snapshot-interval: 1h
        retention: 168h
```

### 5. Vault Secret Path

**Decision**: Use `nomad/default/overseerr` for MinIO credentials

**Rationale**: 
- Secret already created at this path with rw access to `overseerr-litestream` bucket
- Note: The `nomad/data/default/...` style is deprecated in Nomad KV v2 secret engine

**Required Secrets** (confirmed present):
- `MINIO_ACCESS_KEY`
- `MINIO_SECRET_KEY`

### 6. Container Image Multi-Architecture Support

**Decision**: Use `sctx/overseerr:latest` - supports amd64 and arm64

**Rationale**: 
- Official image from Docker Hub
- Multi-arch manifest includes linux/amd64 and linux/arm64
- Allows scheduling on any cluster node (Hestia=amd64, Heracles/Nyx=arm64)

### 7. Resource Requirements

**Decision**: Moderate resources with memory overcommit

**Rationale**: Based on container inspection and similar Node.js apps:
```hcl
resources {
  cpu        = 200
  memory     = 256
  memory_max = 512
}
```

Litestream sidecar:
```hcl
resources {
  cpu        = 100
  memory     = 128
  memory_max = 256
}
```

### 8. Storage Architecture

**Decision**: 
- Ephemeral disk (sticky) for SQLite database
- GlusterFS CSI volume for settings.json and logs

**Rationale**:
- SQLite requires local filesystem for WAL locking - ephemeral disk provides this
- Sticky allocation preserves database across restarts on same node
- Litestream handles cross-node recovery
- settings.json and logs are non-transactional, safe on GlusterFS
- Separating DB from config allows proper litestream operation

**Mount Points**:
| Path | Storage | Content |
|------|---------|---------|
| `/alloc/data/db/` | Ephemeral disk | db.sqlite3, -wal, -shm |
| `/config` | GlusterFS CSI | settings.json, logs/ |

**Note**: Overseerr expects `/app/config` but we'll mount config files separately and symlink if needed, or configure via volume mounts to map appropriately.

### 9. Migration Strategy

**Decision**: Seed litestream backup from existing database before deployment

**Steps**:
1. Stop existing docker-compose Overseerr
2. Create MinIO bucket `overseerr-litestream`
3. Run one-time litestream replicate to seed backup
4. Copy settings.json to GlusterFS volume
5. Deploy Nomad job
6. Verify restore works
7. Remove docker-compose definition

**Rollback**: Keep docker-compose definition until Nomad deployment verified (run both simultaneously is not possible - same port conflict)

## Unknowns Resolved

| Unknown | Resolution |
|---------|------------|
| Health check endpoint | `/api/v1/status` returns JSON with 200 OK |
| Database structure | Single SQLite at `/app/config/db/db.sqlite3` with WAL |
| Sonarr port | 8989 |
| Radarr port | 7878 |
| Multi-arch support | Yes - amd64 and arm64 |
| Vault secret path | `nomad/default/overseerr` (created, rw to bucket) |
| Config file location | `/app/config/settings.json` |
