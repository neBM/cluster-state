# Data Model: ELK to Loki Migration

**Branch**: `011-loki-migration` | **Date**: 2026-03-08

## Overview

This migration replaces an index-based document store (Elasticsearch) with a label-indexed log chunk store (Loki). The fundamental shift is: Elasticsearch indexes every field in every log line; Loki indexes only labels (metadata), compresses raw log lines into chunks, and scans them at query time.

---

## Entities

### 1. Log Stream

The fundamental unit of data in Loki. A stream is defined entirely by its label set — all log lines sharing the same labels form a single stream.

| Attribute | Type | Description |
|---|---|---|
| `namespace` | string (label) | Kubernetes namespace of the source pod |
| `pod` | string (label) | Kubernetes pod name |
| `container` | string (label) | Container name within the pod |
| `node` | string (label) | Kubernetes node where the pod runs |
| `job` | string (label) | `<namespace>/<container>` — used for grouping in Grafana |
| `cluster` | string (label) | Static label: `k3s-homelab` |
| Log line | string (value) | Raw log content — **not indexed**, only stored |
| Timestamp | nanosecond int64 | Log line timestamp (from CRI/container runtime) |

**Cardinality constraint**: Label values must be low-cardinality. The current cluster has ~30 unique containers across 3 namespaces → approximately 90–150 distinct streams. This is well within Loki's recommended limits.

**What is NOT a label** (contrast with Elasticsearch): log level, HTTP status codes, error messages, GeoIP fields, request duration — none of these are indexed. They remain in the raw log line and are extracted at query time via LogQL pipeline stages.

### 2. Chunk

A compressed, immutable block of log lines for a single stream, stored as an object in MinIO.

| Attribute | Type | Description |
|---|---|---|
| Stream labels | map[string]string | Identifies which stream this chunk belongs to |
| Min timestamp | int64 | Earliest log line timestamp in the chunk |
| Max timestamp | int64 | Latest log line timestamp in the chunk |
| Log entries | []Entry | Compressed log lines (Snappy by default) |
| Object path | string | Path in MinIO bucket: `loki/<tenant>/chunks/<hash>` |
| Size | bytes | Typically 256KB–5MB after compression |

Chunks are immutable once flushed from ingester memory to MinIO. They are never modified — only read and eventually deleted by the compactor after the retention period.

### 3. TSDB Index

A time-series-database index mapping stream label sets to the chunks containing their data. Stored as objects in MinIO alongside the chunks.

| Attribute | Type | Description |
|---|---|---|
| Series key | hash | Hash of the label set |
| Chunk refs | []ChunkRef | References to chunks for this stream |
| Period | 24h | Each index shard covers 24 hours (required for retention) |
| Object path | string | `loki/<tenant>/index/<period>/loki_index_<shard>` |

The TSDB index is what Loki queries first when a LogQL query arrives — it resolves the label matchers to chunk references, then fetches only the relevant chunks from MinIO.

### 4. WAL Entry

A write-ahead log entry in the ingester, persisted to local `emptyDir` storage before being flushed to MinIO.

| Attribute | Type | Description |
|---|---|---|
| Log lines | []Entry | Buffered log lines not yet flushed as a chunk |
| Stream | labels | Stream identification |
| Segment file | file | `<ingester.wal.dir>/wal-<segment_id>` on emptyDir |

WAL entries are transient — they exist only until the ingester flushes them to chunks. WAL is lost if the pod is ungracefully killed, but with `flush_on_shutdown: true`, it is flushed on graceful shutdown.

### 5. Alloy WAL (Agent-side)

Grafana Alloy maintains its own WAL on the DaemonSet pods, separate from the Loki WAL.

| Attribute | Type | Description |
|---|---|---|
| Position files | file | `/var/lib/alloy/positions.yaml` — tracks read position per log file |
| WAL data | directory | `/var/lib/alloy/wal/` — buffered log batches before successful delivery to Loki |
| Persistence | hostPath or PVC | Must survive pod restarts to avoid re-reading log files from the beginning |

The Alloy WAL allows Alloy to buffer and retry delivery to Loki during Loki restarts, preventing log loss on the collection side.

---

## Label Schema

### Standard Labels (all streams)

| Label | Source | Example Values | Cardinality |
|---|---|---|---|
| `namespace` | K8s pod metadata | `default`, `kube-system`, `elastic-system` | ~3–5 |
| `pod` | K8s pod metadata | `gitlab-webservice-86446bb468-ddvb6` | ~30–50 (includes hash) |
| `container` | K8s pod metadata | `gitlab-webservice`, `litestream`, `traefik` | ~40–60 |
| `node` | K8s node name | `hestia`, `heracles`, `nyx` | 3 |
| `job` | Composite: `<namespace>/<container>` | `default/gitlab-webservice` | ~40–60 |
| `cluster` | Static (Alloy config) | `k3s-homelab` | 1 |

**Total estimated streams**: ~100–200 (well within Loki limits of ~10,000 per instance)

### Host Log Labels (additional)

| Label | Source | Example Values |
|---|---|---|
| `job` | Static in Alloy config | `node/syslog`, `node/auth`, `journal` |
| `node` | `HOSTNAME` env var in Alloy | `hestia`, `heracles`, `nyx` |
| `unit` | Journal field `_SYSTEMD_UNIT` | `k3s.service`, `sshd.service` |
| `level` | Journal `PRIORITY_KEYWORD` | `info`, `warning`, `error` |

---

## Storage Layout in MinIO

```
minio bucket: loki/
├── <tenant>/               # tenant = "fake" (single-tenant mode)
│   ├── chunks/             # Compressed log chunks (immutable)
│   │   └── <hash>          # Snappy-compressed chunk file
│   ├── index/              # TSDB index shards
│   │   └── <period>/
│   │       └── loki_index_<n>
│   └── compactor/          # Compactor working files
│       └── retention/      # Files marked for deletion (held during delete_delay)
```

**Estimated storage** (based on current ES data):
- Current ES store: ~35 GB (uncompressed equivalent for 30 days)
- Expected Loki store: ~3–6 GB (logs compressed at ~6–10:1 with Snappy)
- Traefik access logs (largest source): currently 21 GB uncompressed → ~2–3 GB in Loki

---

## Data Flow Diagram

```
K8s Pods (stdout/stderr)
    → /var/log/pods/<ns>_<pod>_<uid>/<container>/*.log  (written by containerd/K3s)
    → Alloy DaemonSet (loki.source.file)
        → CRI format parsing (stage.cri)
        → Noise filtering (stage.drop: kube-probe, health checks)
        → Label attachment (namespace, pod, container, node, job, cluster)
        → WAL write (emptyDir on each node)
        → HTTP POST to Loki /loki/api/v1/push

Systemd Journal + Syslog
    → /var/log/journal, /run/log/journal (loki.source.journal)
    → /var/log/syslog, /var/log/auth.log (loki.source.file)
    → Alloy DaemonSet → Loki

Loki (monolithic, single pod)
    → Distributor: receives push, validates, fans out
    → Ingester: buffers in-memory, writes WAL to emptyDir
    → Flusher: compresses chunks, writes to MinIO
    → Compactor: compacts index, enforces 30-day retention, deletes old chunks from MinIO
    → Querier: handles LogQL queries from Grafana
    → Query Frontend: caches query results

Grafana (existing deployment)
    → Loki datasource (provisioned via ConfigMap)
    → Grafana Explore for ad-hoc log searching
```

---

## Terraform Module Structure

```
modules-k8s/
├── loki/
│   ├── main.tf           # Deployment, Service, IngressRoute, ConfigMap (loki.yaml)
│   └── variables.tf      # image_tag, minio_endpoint, minio_bucket, minio_secret_name,
│                         #   retention_period, namespace, ingress_hostname, etc.
├── alloy/
│   ├── main.tf           # DaemonSet, ServiceAccount, ClusterRole/Binding,
│   │                     #   ConfigMap (config.alloy), Service (for metrics)
│   └── variables.tf      # image_tag, loki_url, namespace, etc.
└── grafana/
    └── main.tf           # UPDATED: add Loki datasource to datasources ConfigMap
```

### Modules to Remove (decommission phase)

```
modules-k8s/elk/           # Removed entirely
modules-k8s/elastic-agent/ # Removed entirely
```

### kubernetes.tf Changes

- ADD: `module "k8s_loki"` 
- ADD: `module "k8s_alloy"`
- UPDATE: `module "k8s_grafana"` — add `loki_url` variable
- REMOVE: `module "k8s_elk"`
- REMOVE: `module "k8s_elastic_agent"`

---

## State Transition: Log Data Lifecycle

```
[Container emits log line]
    ↓
[Alloy: tail /var/log/pods file] → [Alloy WAL: buffer on node emptyDir]
    ↓
[Loki distributor: receive push]
    ↓
[Loki ingester: in-memory + WAL on pod emptyDir]
    ↓ (flush every ~1-5 min or when chunk full)
[MinIO: immutable chunk stored as S3 object]
    ↓ (compactor runs every 10min)
[TSDB index updated in MinIO]
    ↓ (after 30 days = 720h)
[Compactor marks chunk for deletion]
    ↓ (after 2h delete_delay grace period)
[MinIO: chunk deleted]
```

---

## Validation Rules (from FR requirements)

| Requirement | Validation |
|---|---|
| FR-001: All pod logs collected | Query Loki for all `namespace=default` pods; verify each container has entries |
| FR-002: Required labels present | LogQL `{namespace="", pod="", container="", node="", job=""}` must not return empty on known active pods |
| FR-003: MinIO backend | Check MinIO console for `loki/` bucket with chunk objects |
| FR-004: 30-day retention | Verify `limits_config.retention_period: 720h` and `compactor.retention_enabled: true` |
| FR-009: Noise filtering | Query for `|= "kube-probe"` — must return zero results |
| FR-010: All nodes covered | Query with `node="hestia"`, `node="heracles"`, `node="nyx"` — all must have recent entries |
