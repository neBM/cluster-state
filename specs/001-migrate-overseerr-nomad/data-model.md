# Data Model: Migrate Overseerr to Nomad

**Date**: 2026-01-20
**Branch**: `001-migrate-overseerr-nomad`

## Infrastructure Entities

### 1. Nomad Job: `overseerr`

**Type**: Service job (long-running)
**Datacenters**: dc1
**Namespace**: default

```
Job: overseerr
└── Group: overseerr
    ├── Network: bridge mode, port 5055
    ├── Ephemeral Disk: 100MB, sticky, migrate
    ├── Volume: glusterfs_overseerr_config (CSI)
    │
    ├── Task: litestream-restore (prestart)
    │   ├── Image: litestream/litestream:0.5
    │   ├── Lifecycle: prestart, non-sidecar
    │   └── Purpose: Restore DB from MinIO if not on ephemeral disk
    │
    ├── Task: overseerr (main)
    │   ├── Image: sctx/overseerr:latest
    │   ├── Port: 5055
    │   ├── Volume mount: /config (CSI)
    │   └── Bind mount: /alloc/data/db → /app/config/db
    │
    └── Task: litestream (sidecar)
        ├── Image: litestream/litestream:0.5
        ├── Lifecycle: poststart, sidecar
        └── Purpose: Continuous replication to MinIO
```

### 2. CSI Volume: `glusterfs_overseerr_config`

| Attribute | Value |
|-----------|-------|
| Plugin ID | glusterfs |
| Access Mode | single-node-writer |
| Attachment Mode | file-system |
| Capacity Min | 100MiB |
| Capacity Max | 1GiB |
| Lifecycle | prevent_destroy |

**Contents**:
- `settings.json` - Overseerr configuration
- `logs/` - Application logs

### 3. MinIO Bucket: `overseerr-litestream`

| Attribute | Value |
|-----------|-------|
| Name | overseerr-litestream |
| Access | Private |
| Versioning | Disabled (litestream manages versions) |
| Lifecycle | None (litestream manages retention) |

**Contents**:
- `db/` - Litestream snapshots and WAL segments

### 4. Vault Secret: `nomad/default/overseerr`

| Key | Description | Status |
|-----|-------------|--------|
| MINIO_ACCESS_KEY | MinIO access key for litestream | Created |
| MINIO_SECRET_KEY | MinIO secret key for litestream | Created |

**Note**: Credentials have rw access to `overseerr-litestream` bucket.

### 5. Consul Service: `overseerr`

| Attribute | Value |
|-----------|-------|
| Provider | consul |
| Port | 5055 |
| Connect | Sidecar with transparent proxy |
| Health Check | HTTP GET /api/v1/status |

**Traefik Tags**:
```
traefik.enable=true
traefik.http.routers.overseerr.rule=Host(`overseerr.brmartin.co.uk`)
traefik.http.routers.overseerr.entrypoints=websecure
traefik.consulcatalog.connect=true
```

## Entity Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                        Nomad Job                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Group: overseerr                       │   │
│  │                                                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │ litestream- │  │  overseerr  │  │ litestream  │      │   │
│  │  │   restore   │──│   (main)    │──│  (sidecar)  │      │   │
│  │  │  (prestart) │  │             │  │ (poststart) │      │   │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘      │   │
│  │         │                │                │              │   │
│  │         │         ┌──────┴──────┐         │              │   │
│  │         │         │ /alloc/data │         │              │   │
│  │         │         │ (ephemeral) │         │              │   │
│  │         │         │  db.sqlite3 │         │              │   │
│  │         │         └─────────────┘         │              │   │
│  │         │                                 │              │   │
│  │         └────────────────┬────────────────┘              │   │
│  │                          │                               │   │
│  │                          ▼                               │   │
│  │                  ┌───────────────┐                       │   │
│  │                  │     MinIO     │                       │   │
│  │                  │  (via Consul) │                       │   │
│  │                  │ overseerr-    │                       │   │
│  │                  │  litestream   │                       │   │
│  │                  └───────────────┘                       │   │
│  │                                                           │   │
│  │  ┌─────────────────────────────────────────────────┐    │   │
│  │  │              CSI Volume (GlusterFS)              │    │   │
│  │  │         glusterfs_overseerr_config               │    │   │
│  │  │  ┌─────────────────┐  ┌───────────────────┐     │    │   │
│  │  │  │  settings.json  │  │       logs/       │     │    │   │
│  │  │  └─────────────────┘  └───────────────────┘     │    │   │
│  │  └─────────────────────────────────────────────────┘    │   │
│  └───────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Consul Connect
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Traefik                                  │
│              overseerr.brmartin.co.uk:443                       │
└─────────────────────────────────────────────────────────────────┘
```

## State Transitions

### Job Lifecycle States

```
[Pending] ──► [Running] ◄──► [Draining]
    │             │              │
    │             │              │
    ▼             ▼              ▼
[Failed]     [Complete]     [Rescheduled]
```

### Task Execution Order

```
1. [litestream-restore]  ─── prestart hook
        │
        ▼
2. [Connect sidecar]     ─── automatic (transparent proxy)
        │
        ▼
3. [overseerr]           ─── main task
        │
        ▼
4. [litestream]          ─── poststart sidecar (parallel with main)
```

## Validation Rules

| Entity | Rule | Error Behavior |
|--------|------|----------------|
| CSI Volume | Must exist before job | Job pending until volume available |
| MinIO Bucket | Must exist for litestream | Restore fails, starts with empty DB |
| Vault Secret | Must contain MINIO_* keys | Template render fails, job doesn't start |
| Health Check | HTTP 200 within 30s | Task marked unhealthy, Traefik removes |
