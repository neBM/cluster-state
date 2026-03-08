# Component Interfaces: ELK to Loki Migration

**Branch**: `011-loki-migration` | **Date**: 2026-03-08

This document defines the interfaces between components in the new logging stack. Since this is a pure infrastructure migration (no application APIs), "contracts" here describe the configuration interfaces between Terraform modules and the runtime expectations each component has of its neighbours.

---

## Component Map

```
┌─────────────────────────────────────────────────────┐
│  Grafana Alloy DaemonSet (modules-k8s/alloy)        │
│  • Input:  /var/log/pods (hostPath)                 │
│  • Input:  /var/log/journal, /var/log (hostPath)    │
│  • Output: HTTP POST → Loki :3100                   │
└────────────────────────┬────────────────────────────┘
                         │ HTTP (Loki push API)
                         ▼
┌─────────────────────────────────────────────────────┐
│  Loki (modules-k8s/loki)                            │
│  • Input:  HTTP :3100  (from Alloy)                 │
│  • Input:  HTTP :3100  (query from Grafana)         │
│  • Output: S3 PUT/GET  → MinIO                      │
└──────────────┬──────────────────────────────────────┘
               │ S3 API (HTTP)        │ HTTP (query)
               ▼                      ▼
┌─────────────────────┐   ┌─────────────────────────┐
│  MinIO              │   │  Grafana (existing)      │
│  (modules-k8s/minio)│   │  (modules-k8s/grafana)  │
│  Bucket: loki       │   │  Datasource: Loki        │
└─────────────────────┘   └─────────────────────────┘
```

---

## Interface 1: Alloy → Loki (Log Push)

**Protocol**: HTTP/1.1 POST  
**Endpoint**: `http://loki.default.svc.cluster.local:3100/loki/api/v1/push`  
**Content-Type**: `application/x-protobuf` or `application/json`  
**Authentication**: None (`auth_enabled: false` in Loki)

### Request Contract (Alloy side — `loki.write`)
```
Alloy config:
  loki.write "loki" {
    endpoint {
      url = "http://loki.default.svc.cluster.local:3100/loki/api/v1/push"
    }
  }
```
Alloy automatically batches log lines, manages backpressure, and retries on failure (with exponential backoff). No headers required for single-tenant mode.

### Response Contract (Loki side)
| HTTP Status | Meaning |
|---|---|
| `204 No Content` | Push accepted successfully |
| `400 Bad Request` | Malformed request (e.g., out-of-order timestamps) |
| `429 Too Many Requests` | Ingestion rate limit exceeded |
| `500 Internal Server Error` | Loki internal error |

Alloy retries on 429 and 5xx responses using its built-in WAL-backed retry mechanism.

### Assumptions
- Loki service is accessible at `loki.default.svc.cluster.local:3100` (ClusterIP)
- No TLS on the internal path (HTTP only)
- Alloy handles back-pressure automatically; Loki need not be available at all times

---

## Interface 2: Grafana → Loki (Query)

**Protocol**: HTTP/1.1 GET  
**Base URL**: `http://loki.default.svc.cluster.local:3100`  
**Authentication**: None  
**Datasource type**: `loki`

### Grafana Datasource Provisioning Contract

This is the configuration Grafana requires from the `modules-k8s/grafana` module:

```yaml
# Added to grafana-datasources ConfigMap (datasources/loki.yaml key)
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    uid: loki                           # Fixed UID for dashboard references
    access: proxy
    url: http://loki.default.svc.cluster.local:3100
    isDefault: false
    editable: true
    jsonData:
      maxLines: 1000
      timeout: 60
    version: 1
```

### Key LogQL Queries (validated interface)

These queries must return results once the stack is operational:

```logql
# All logs from a specific container
{namespace="default", container="gitlab-webservice"}

# Text search within a service
{namespace="default", container="synapse"} |= "error"

# All logs from a specific node
{node="hestia"}

# Journal logs
{job="journal"} | unit="k3s.service"

# Traefik access logs (automatic via pod pipeline)
{namespace="default", container="traefik"}

# Verify noise filter works (must return no results)
{namespace="default"} |= "kube-probe"
```

### Grafana Module Interface (variables)

New variable added to `modules-k8s/grafana/variables.tf` and module call in `kubernetes.tf`:

```hcl
variable "loki_url" {
  type        = string
  description = "Loki query URL for Grafana datasource"
  default     = "http://loki.default.svc.cluster.local:3100"
}
```

---

## Interface 3: Loki → MinIO (Object Storage)

**Protocol**: HTTP/1.1 (S3-compatible API)  
**Endpoint**: `http://minio-api.default.svc.cluster.local:9000`  
**Authentication**: AWS S3 credentials via env vars

### MinIO Credentials Contract

A Kubernetes Secret `loki-minio` must exist in the `default` namespace **before** Loki starts:

```
Secret name: loki-minio
Namespace:   default
Keys:
  MINIO_ACCESS_KEY   = <dedicated loki MinIO user access key>
  MINIO_SECRET_KEY   = <dedicated loki MinIO user secret key>
```

These are injected into the Loki container as:
```
AWS_ACCESS_KEY_ID     ← MINIO_ACCESS_KEY
AWS_SECRET_ACCESS_KEY ← MINIO_SECRET_KEY
```

### MinIO Bucket Pre-conditions

Before `terraform apply` creates the Loki Deployment:
1. Bucket `loki` must exist in MinIO
2. The MinIO user must have `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the `loki` bucket

**Bucket creation** is handled by a Kubernetes Job run via `terraform_data` provisioner or manual pre-step (see quickstart.md).

### S3 API Operations Used by Loki
| Operation | Purpose |
|---|---|
| `PutObject` | Write chunk and index files |
| `GetObject` | Read chunks for query |
| `DeleteObject` | Delete expired chunks (compactor) |
| `ListObjectsV2` | Enumerate chunks for compaction |
| `HeadObject` | Check chunk existence |

---

## Interface 4: Alloy → Kubernetes API (Discovery)

**Protocol**: HTTPS (K8s API server)  
**Authentication**: ServiceAccount token (auto-mounted)  
**Namespace**: `default` (Alloy DaemonSet namespace)

### RBAC Contract

`ClusterRole` bound to `alloy` ServiceAccount:

```yaml
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods", "services", "endpoints", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes/proxy"]
    verbs: ["get"]
```

This is less permissive than the current Elastic Agent ClusterRole (which also accesses `storageclasses`, `replicasets`, `daemonsets`, etc. — not needed for log collection).

---

## Interface 5: Alloy → Host Filesystem (Log Reading)

**Mount type**: `hostPath` (read-only where possible)

| Host Path | Container Mount | Read-only | Purpose |
|---|---|---|---|
| `/var/log/pods` | `/var/log/pods` | Yes | K3s/containerd pod logs |
| `/var/log/journal` | `/var/log/journal` | Yes | Persistent systemd journal |
| `/run/log/journal` | `/run/log/journal` | Yes | Volatile systemd journal |
| `/var/log` | `/var/log` | Yes | Syslog, auth.log |

**State persistence** (read-write):

| Volume | Type | Mount | Purpose |
|---|---|---|---|
| `alloy-positions` | hostPath DirectoryOrCreate | `/var/lib/alloy` | Position files + agent WAL |

The positions hostPath persists across Alloy pod restarts on the same node, preventing re-reading of already-shipped logs.

---

## Decommissioned Interfaces (to be removed)

| Interface | Current | After Migration |
|---|---|---|
| Elastic Agent → Fleet Server | `https://192.168.1.5:8220` (enrollment) | REMOVED |
| Elastic Agent → Elasticsearch | Elasticsearch ClusterIP :9200 | REMOVED |
| Kibana → Elasticsearch | `https://elasticsearch:9200` | REMOVED |
| External ES API | `https://es.brmartin.co.uk` (Traefik) | REMOVED |
| External Kibana | `https://kibana.brmartin.co.uk` (Traefik) | REMOVED |
| Elastic Agent enrollment secret | `elastic-system/elastic-agent-enrollment` | REMOVED |
| Kibana credentials (ESO) | ExternalSecret from Vault | REMOVED |

---

## Kubernetes Resources: New vs Removed

### New Resources

| Resource | Module | Notes |
|---|---|---|
| `Deployment/loki` | `modules-k8s/loki` | Single-pod Loki |
| `Service/loki` | `modules-k8s/loki` | ClusterIP :3100 |
| `IngressRoute/loki` | `modules-k8s/loki` | Optional — internal only, no external access needed |
| `ConfigMap/loki-config` | `modules-k8s/loki` | `loki.yaml` content |
| `Secret/loki-minio` | Manual / Vault | MinIO credentials for Loki |
| `DaemonSet/alloy` | `modules-k8s/alloy` | One pod per node |
| `ServiceAccount/alloy` | `modules-k8s/alloy` | |
| `ClusterRole/alloy` | `modules-k8s/alloy` | |
| `ClusterRoleBinding/alloy` | `modules-k8s/alloy` | |
| `ConfigMap/alloy-config` | `modules-k8s/alloy` | `config.alloy` |
| `ConfigMap/grafana-datasources` | `modules-k8s/grafana` | UPDATED: add Loki entry |

### Removed Resources

| Resource | Module | Notes |
|---|---|---|
| `StatefulSet/elasticsearch-data-*` | `modules-k8s/elk` | 2 pods |
| `StatefulSet/elasticsearch-tiebreaker-*` | `modules-k8s/elk` | 1 pod |
| `Deployment/kibana` | `modules-k8s/elk` | |
| `DaemonSet/elastic-agent` | `modules-k8s/elastic-agent` | |
| `Namespace/elastic-system` | `modules-k8s/elastic-agent` | |
| `PVC/elasticsearch-data-0` | `modules-k8s/elk` | 50Gi local NVMe |
| `PVC/elasticsearch-data-1` | `modules-k8s/elk` | 50Gi local NVMe |
| `IngressRoute/elasticsearch` | `modules-k8s/elk` | `es.brmartin.co.uk` |
| `IngressRoute/kibana` | `modules-k8s/elk` | `kibana.brmartin.co.uk` |
| `ExternalSecret/kibana-*` | `modules-k8s/elk/secrets.tf` | 3 ExternalSecrets |
| `Secret/elastic-certificates` | `modules-k8s/elk` | TLS keypair |
| Various `ClusterRole*` | `modules-k8s/elastic-agent` | |
