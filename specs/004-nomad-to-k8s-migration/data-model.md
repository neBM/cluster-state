# Data Model: Nomad to Kubernetes Resource Mapping

**Phase**: 1 - Design  
**Date**: 2026-01-22

## Nomad → Kubernetes Resource Mapping

| Nomad Concept | Kubernetes Equivalent | Notes |
|---------------|----------------------|-------|
| Job | Deployment/StatefulSet/CronJob | Based on workload type |
| Task Group | Pod | Group of containers |
| Task | Container | Single container definition |
| Service (Consul) | Service + Ingress | Service discovery + routing |
| CSI Volume | PV + PVC or hostPath | Storage attachment |
| Template (secrets) | ExternalSecret | Vault integration |
| Periodic Job | CronJob | Scheduled execution |
| Constraint | nodeSelector/affinity | Node placement |

## Service Categories

### Category A: Stateless Services

**Characteristics**: No persistent data, can restart anywhere

| Service | K8s Workload | Storage | Special |
|---------|--------------|---------|---------|
| searxng | Deployment | hostPath (config) | OAuth middleware |
| nginx-sites | Deployment | hostPath (code) | Multiple hostnames |

**Pattern**: Simple Deployment with ConfigMap/Secrets

---

### Category B: Litestream Services (SQLite)

**Characteristics**: SQLite database backed up to MinIO via litestream sidecar

| Service | K8s Workload | Storage | Litestream Bucket |
|---------|--------------|---------|-------------------|
| vaultwarden | StatefulSet | emptyDir (db) + hostPath (config) | vaultwarden-litestream |
| overseerr | StatefulSet | emptyDir (db) + hostPath (config) | overseerr-litestream |
| open-webui | StatefulSet | emptyDir (db) | openwebui-litestream |

**Pattern**: StatefulSet with init container (restore) + sidecar (replicate)

---

### Category C: GlusterFS Services (Persistent Data)

**Characteristics**: Data stored on GlusterFS, accessed via NFS

| Service | K8s Workload | Volumes |
|---------|--------------|---------|
| minio | StatefulSet | `/storage/v/glusterfs_minio_data` |
| keycloak | StatefulSet | `/storage/v/glusterfs_keycloak_*` |
| appflowy | StatefulSet | `/storage/v/glusterfs_appflowy_*` |
| elk | StatefulSet | `/storage/v/glusterfs_elk_*` |
| nextcloud | StatefulSet | `/storage/v/glusterfs_nextcloud_*` |
| matrix | StatefulSet | `/storage/v/glusterfs_matrix_*` |
| gitlab | StatefulSet | `/storage/v/glusterfs_gitlab_*` |

**Pattern**: StatefulSet with hostPath volumes pointing to GlusterFS mount

---

### Category D: GPU Workloads

**Characteristics**: Requires NVIDIA GPU, pinned to Hestia

| Service | K8s Workload | GPU | Notes |
|---------|--------------|-----|-------|
| ollama | Deployment | 1 GPU | Node selector for Hestia |

**Pattern**: Deployment with GPU resource request + nodeSelector

---

### Category E: Periodic Jobs

**Characteristics**: Run on schedule, not continuously

| Service | K8s Workload | Schedule | Notes |
|---------|--------------|----------|-------|
| renovate | CronJob | TBD | GitLab integration |
| restic-backup | CronJob | Daily | Backup to external storage |

**Pattern**: CronJob with appropriate schedule

---

### Category F: Background Workers

**Characteristics**: No external access, supports other services

| Service | K8s Workload | Notes |
|---------|--------------|-------|
| gitlab-runner | Deployment | Docker-in-Docker |

**Pattern**: Deployment without Ingress

---

## Entity Details by Service

### searxng

```yaml
Namespace: default
Deployment:
  replicas: 1
  containers:
    - searxng: port 8080
  volumes:
    - config: hostPath /storage/v/glusterfs_searxng_config
Service:
  port: 80 → 8080
Ingress:
  host: searx.brmartin.co.uk
  middlewares: oauth-auth@docker (via external Traefik)
ExternalSecret: None (no secrets in Vault)
```

### nginx-sites

```yaml
Namespace: default
Deployment:
  replicas: 1
  containers:
    - nginx: port 80
  volumes:
    - code: hostPath /storage/v/glusterfs_nginx_sites_code
Service:
  port: 80 → 80
Ingress:
  hosts:
    - brmartin.co.uk
    - www.brmartin.co.uk
    - martinilink.co.uk
    - *.martinilink.co.uk
ExternalSecret: None
```

### vaultwarden

```yaml
Namespace: default
StatefulSet:
  replicas: 1
  initContainers:
    - litestream-restore
  containers:
    - vaultwarden: port 80
    - litestream (sidecar)
  volumes:
    - data: emptyDir (SQLite, ephemeral)
    - config: hostPath /storage/v/glusterfs_vaultwarden_data
Service:
  port: 80 → 80
Ingress:
  host: bw.brmartin.co.uk
ExternalSecret:
  - DATABASE_URL
  - SMTP_PASSWORD
  - ADMIN_TOKEN
ConfigMap:
  - litestream.yml
```

### overseerr

```yaml
Namespace: default
StatefulSet:
  replicas: 1
  initContainers:
    - litestream-restore
  containers:
    - overseerr: port 5055
    - litestream (sidecar)
  volumes:
    - data: emptyDir (SQLite db)
    - config: hostPath /storage/v/glusterfs_overseerr_config
Service:
  port: 80 → 5055
Ingress:
  host: overseerr.brmartin.co.uk  # NOT overseerr-k8s
ExternalSecret:
  - MINIO_ACCESS_KEY
  - MINIO_SECRET_KEY
ConfigMap:
  - litestream.yml
```

### minio

```yaml
Namespace: default
StatefulSet:
  replicas: 1
  containers:
    - minio: ports 9000 (S3), 9001 (console)
  volumes:
    - data: hostPath /storage/v/glusterfs_minio_data
Service:
  - minio: port 9000 (S3 API)
  - minio-console: port 9001 (web UI)
Ingress:
  host: minio.brmartin.co.uk → console
ExternalSecret:
  - MINIO_ROOT_USER
  - MINIO_ROOT_PASSWORD
```

### keycloak

```yaml
Namespace: default
StatefulSet:
  replicas: 1
  containers:
    - keycloak: port 8080
  volumes:
    - data: hostPath /storage/v/glusterfs_keycloak_data
Service:
  port: 80 → 8080
Ingress:
  host: sso.brmartin.co.uk
ExternalSecret:
  - KEYCLOAK_ADMIN_PASSWORD
  - KC_DB_PASSWORD
```

### ollama

```yaml
Namespace: default
Deployment:
  replicas: 1
  containers:
    - ollama: port 11434
  volumes:
    - models: hostPath /storage/v/glusterfs_ollama_data
  resources:
    limits:
      nvidia.com/gpu: 1
  nodeSelector:
    kubernetes.io/hostname: hestia
Service:
  port: 11434 → 11434 (internal only)
Ingress: None (internal service)
```

### open-webui

```yaml
Namespace: default
StatefulSet:
  replicas: 1
  initContainers:
    - litestream-restore
  containers:
    - open-webui: port 8080
    - litestream (sidecar)
  volumes:
    - data: emptyDir (SQLite db)
Service:
  port: 80 → 8080
Ingress:
  host: chat.brmartin.co.uk
ExternalSecret:
  - MINIO_ACCESS_KEY
  - MINIO_SECRET_KEY
  - OPENAI_API_KEY (if any)
```

### Complex Services (gitlab, matrix, nextcloud, elk, appflowy)

These require detailed analysis during implementation. Key patterns:
- Multiple containers per pod (or separate pods)
- Multiple volumes per service
- Inter-service dependencies
- Complex health checks

---

## Volume Path Mapping

| Nomad CSI Volume | K8s hostPath |
|------------------|--------------|
| `glusterfs_<service>_<type>` | `/storage/v/glusterfs_<service>_<type>` |

Example:
- Nomad: `glusterfs_vaultwarden_data` 
- K8s: `/storage/v/glusterfs_vaultwarden_data`

---

## State Transitions

### Migration State Machine (per service)

```
[Running on Nomad]
       │
       ▼ (nomad job stop <service>)
[Stopped on Nomad]
       │
       ▼ (terraform apply - K8s module)
[Starting on K8s]
       │
       ▼ (health check passes)
[Running on K8s]
       │
       ▼ (verify URL + data)
[Verified on K8s]
       │
       ▼ (update external Traefik)
[Migrated Complete]
```

### Rollback Path

```
[Failed on K8s]
       │
       ▼ (kubectl delete deployment/statefulset)
[K8s Workload Removed]
       │
       ▼ (nomad job run modules/<service>/jobspec.nomad.hcl)
[Restored on Nomad]
```
