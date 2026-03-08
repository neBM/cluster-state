# Research: ELK to Loki Migration

**Branch**: `011-loki-migration` | **Date**: 2026-03-08

## Summary of Decisions

| Topic | Decision | Rationale |
|---|---|---|
| Loki deployment mode | Monolithic (single pod, `-target=all`) | Appropriate for homelab log volume; simplest ops |
| Storage backend | MinIO via S3-compatible API | Already deployed; zero new infrastructure |
| MinIO endpoint | `http://minio-api.default.svc.cluster.local:9000` | Internal ClusterIP, avoids Traefik hop |
| Log collection agent | Grafana Alloy DaemonSet | Modern replacement for Promtail; better K8s integration |
| Alloy log path | `/var/log/pods` (containerd/K3s native path) | K3s uses containerd, not Docker; correct path is `/var/log/pods` |
| Loki WAL storage | `emptyDir` (ephemeral) | NFS has known WAL/SQLite issues in this cluster; acceptable for homelab |
| Schema version | TSDB v13 | Current recommended schema; superior query performance |
| Retention mechanism | Compactor-based (`retention_enabled: true`) | Only mechanism supported with TSDB/S3 storage |
| Authentication | Disabled (`auth_enabled: false`) | Single-user homelab; no multi-tenancy needed |
| Traefik access logs | Collected automatically via pod log pipeline | Traefik writes to stdout → `/var/log/pods`; no special handling needed |
| Journal/syslog collection | `loki.source.journal` + `loki.source.file` | Journal for systemd, file for syslog/auth.log |

---

## Loki Configuration

### Confirmed Minimal `loki.yaml`

```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9095

common:
  instance_addr: 127.0.0.1
  ring:
    kvstore:
      store: inmemory   # No etcd/consul needed for single-pod
  replication_factor: 1
  path_prefix: /loki    # WAL at /loki/wal, index at /loki/index

schema_config:
  configs:
    - from: "2024-01-01"      # Must be a past date
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: loki_index_
        period: 24h           # Required for compactor retention

storage_config:
  aws:
    bucketnames: loki
    endpoint: minio-api.default.svc.cluster.local:9000
    insecure: true            # HTTP to internal MinIO
    s3forcepathstyle: true    # Required for MinIO
    region: us-east-1         # MinIO ignores region but SDK requires non-empty
    # access_key_id / secret_access_key read from env vars:
    # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache

ingester:
  wal:
    enabled: true
    dir: /loki/wal            # Mounted as emptyDir (NOT NFS)
    flush_on_shutdown: true   # Flush to S3 on graceful shutdown

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150
  delete_request_store: s3

limits_config:
  retention_period: 720h    # 30 days
```

### Key Constraints
- **`s3forcepathstyle: true`** is mandatory for MinIO (virtual-hosted-style URLs don't work)
- **`index.period: 24h`** is required for compactor retention to function
- **`delete_request_store: s3`** must match `schema_config.object_store` value exactly
- **`auth_enabled: false`** means all traffic goes to the internal `"fake"` tenant — do NOT set `X-Scope-OrgID` header in Grafana datasource

### Exposed Ports and Health Endpoints
| Port | Protocol | Purpose |
|---|---|---|
| 3100 | HTTP | Push API, query API, `/ready`, `/metrics`, `/config` |
| 9095 | gRPC | Internal component communication |

Health endpoints (port 3100):
- `GET /ready` — returns HTTP 200 when Loki is ready; use for readinessProbe
- `GET /metrics` — Prometheus metrics
- `GET /loki/api/v1/push` — log ingestion endpoint (POST)
- `GET /loki/api/v1/query_range` — range query endpoint

---

## WAL Storage Decision

**Decision**: Use `emptyDir` for WAL. Do NOT use GlusterFS/NFS.

**Rationale**: The cluster has a documented constraint against SQLite/WAL on network filesystems (AGENTS.md: "SQLite on Network Storage — use ephemeral disk"). The WAL in Loki uses a similar append-only log file pattern. Using emptyDir means the WAL survives container crashes (same pod restarts) but not pod deletions. With `flush_on_shutdown: true`, graceful restarts (e.g. `kubectl rollout restart`) flush data to MinIO before the pod terminates, preventing loss.

**Acceptable risk**: On an ungraceful pod termination (OOMKill, node failure), log lines buffered since the last WAL checkpoint (~few seconds to minutes) may be lost. This is acceptable for a homelab logging stack.

---

## Grafana Alloy Configuration

### Pod Log Collection (Primary)

**Source**: `/var/log/pods/<namespace>_<pod>_<uid>/<container>/<n>.log` — the native K3s/containerd path.

**Host volumes required**:
| Host Path | Mount | Purpose |
|---|---|---|
| `/var/log/pods` | `/var/log/pods` | Container stdout/stderr logs (primary) |
| `/var/log/journal` | `/var/log/journal` | Persistent systemd journal |
| `/run/log/journal` | `/run/log/journal` | Volatile systemd journal (fallback) |
| `/var/log` | `/var/log` | Syslog, auth.log (read-only) |

**RBAC required** (`ClusterRole`):
- `get`, `list`, `watch` on: `nodes`, `pods`, `services`, `endpoints`, `namespaces`

**Key Alloy pipeline**:
1. `discovery.kubernetes "pods"` — discovers pods on the local node via K8s API
2. `discovery.relabel "pod_logs"` — extracts namespace, pod, container, node labels; constructs `__path__` to log file
3. `local.file_match "pod_logs"` — matches discovered log file paths on disk
4. `loki.source.file "pod_logs"` — tails matched files
5. `loki.process "pod_logs"` — parses CRI format, drops probe noise, adds cluster label
6. `loki.write "loki"` — pushes to Loki HTTP API

**Label cardinality strategy**: Labels are strictly limited to:
- `namespace`, `pod`, `container`, `node`, `job`, `cluster`

Log content is never used as a label. High-cardinality metadata (UIDs, IP addresses) is dropped.

### Noise Filtering (drops before storage)
- Lines matching `.*kube-probe.*` (kube-liveness/readiness probe user-agent)
- Lines matching `.*(GET|HEAD) /health.* 200` (health check log noise)

### Host Log Collection (Secondary)
- **Journal**: `loki.source.journal` — reads systemd journal directly via libsystemd. Extracts `unit`, `level` labels.
- **Syslog/auth**: `local.file_match` targeting `/var/log/syslog` and `/var/log/auth.log`

**Permission note**: Reading `/var/log/auth.log` requires the container to run as root or with supplementary group `adm` (GID 4). Running as root (same as elastic-agent today) is the simplest approach and consistent with the existing setup.

### Traefik Access Logs
No special handling needed. Traefik writes to stdout → captured by containerd → stored under `/var/log/pods` → picked up by the standard pod log pipeline. Labelled automatically as `namespace=default, container=traefik`.

---

## MinIO Setup

### Bucket Creation
Loki **does not auto-create** the bucket. The `loki` bucket must be pre-created before Loki starts. This is done via a Kubernetes Job or init container using the `mc` CLI:
```sh
mc alias set minio http://minio-api.default.svc.cluster.local:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
mc mb --ignore-existing minio/loki
```

### Dedicated Credentials
A dedicated MinIO user with a scoped policy (not the root account) should be used. Required permissions:
- `s3:ListBucket` on `arn:aws:s3:::loki`
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `arn:aws:s3:::loki/*`

The credentials are stored in a Kubernetes Secret and injected as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars into the Loki pod.

---

## Grafana Datasource Provisioning

The existing Grafana module mounts additional datasource files from a ConfigMap at `/etc/grafana/provisioning/datasources/`. A new `loki.yaml` key is added to the existing `kubernetes_config_map.datasources` resource (or a separate ConfigMap is added and mounted at the same path).

```yaml
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki.default.svc.cluster.local:3100
    isDefault: false
    editable: true
    jsonData:
      maxLines: 1000
      timeout: 60
```

**Important**: Do NOT set `httpHeaderName1: X-Scope-OrgID` — with `auth_enabled: false`, Loki uses the `"fake"` tenant and the header would cause a mismatch.

---

## Constitution Compliance Check

| Principle | Status | Notes |
|---|---|---|
| I. Infrastructure as Code | PASS | All changes via Terraform modules |
| II. Simplicity First | PASS | One new module (`modules-k8s/loki`), one updated module (`modules-k8s/alloy`). No unnecessary abstractions. |
| III. High Availability | ACCEPTABLE | Single Loki pod — no HA. Acceptable for homelab logs; Alloy DaemonSet buffers during brief Loki restarts. |
| IV. Storage Patterns | PASS | WAL on emptyDir (not NFS), chunks on MinIO. Matches established pattern for ephemeral-disk-with-remote-backup. |
| V. Security & Secrets | PASS | Dedicated MinIO credentials per-service (not root account), stored in K8s Secret |
| VI. Service Mesh Patterns | N/A | Consul/Nomad not used; K8s networking direct |

**Constitution violation: HA** — Single Loki pod is a single point of failure for log ingestion. This is accepted because:
1. Alloy DaemonSet buffers logs during Loki restarts (backpressure, WAL-on-alloy)
2. Loki monolithic HA (ring-based multi-pod) is significantly more complex and requires a distributed KV store
3. Log collection is not a hard dependency for any service — no service fails if Loki is temporarily unavailable

---

## Alternatives Considered

| Alternative | Why Rejected |
|---|---|
| OpenSearch | JVM-based; same RAM footprint as Elasticsearch; no resource improvement |
| Quickwit | Acquired by Datadog Jan 2025; OSS future uncertain |
| Loki Simple Scalable mode | 3 StatefulSets (write/read/backend); overkill for homelab; requires more K8s resources than monolithic |
| Promtail (instead of Alloy) | Alloy is the officially recommended successor; Promtail is in maintenance mode |
| Loki with GlusterFS PVC for WAL | Known SQLite/WAL issues on NFS in this cluster (AGENTS.md documented constraint) |
| Keeping Elasticsearch + adding Loki | Defeats the goal of freeing RAM; two logging stacks to maintain |
