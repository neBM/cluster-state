# Implementation Plan: ELK to Loki Migration

**Branch**: `011-loki-migration` | **Date**: 2026-03-08 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/011-loki-migration/spec.md`

## Summary

Replace the 3-node Elasticsearch cluster (Kibana + Elastic Agent DaemonSet, ~11 GB RAM total) with Grafana Loki in monolithic mode backed by the existing MinIO deployment, and Grafana Alloy as the collection agent DaemonSet. Loki stores compressed log chunks in MinIO (S3-compatible) and exposes a query API consumed by the existing Grafana instance. Historical ES data is dropped. APM and ingest enrichment pipelines are not replicated. Expected RAM savings: ≥9 GB cluster-wide, taking Heracles from 100% to ~60% RAM.

## Technical Context

**Language/Version**: HCL (Terraform 1.x) — same as all other modules  
**Primary Dependencies**:
- `grafana/loki:3.4.1` (monolithic, multi-arch amd64+arm64)
- `grafana/alloy:v1.7.1` (DaemonSet, multi-arch amd64+arm64)
- MinIO (existing) — S3-compatible object store for Loki chunks and index
- Grafana (existing) — UI for log browsing via Loki datasource

**Storage**:
- Loki WAL: `emptyDir` (ephemeral, per cluster SQLite-on-NFS constraint)
- Loki chunks/index: MinIO bucket `loki` (S3 API)
- Alloy positions/WAL: `hostPath DirectoryOrCreate` at `/var/lib/alloy` on each node

**Testing**: Manual verification via `kubectl`, Grafana Explore queries, MinIO console  
**Target Platform**: Kubernetes (K3s 1.34+), 3-node mixed-arch (amd64 Hestia + arm64 Heracles/Nyx)  
**Project Type**: Infrastructure — new Terraform modules + updates to existing modules  
**Performance Goals**:
- Logs visible in Grafana within 60 seconds of emission
- Text search over 1-hour window completes in under 10 seconds
- Log storage: under 10 GB for 30 days (vs. current 35 GB in ES)

**Constraints**:
- WAL must NOT use GlusterFS/NFS (cluster-wide constraint, AGENTS.md)
- No changes to any deployed application or service (pure infrastructure)
- Alloy DaemonSet must tolerate control-plane taint (all 3 nodes)
- MinIO credentials must be per-service (dedicated `loki` user, not root)

**Scale/Scope**: ~100–200 Loki log streams; ~3–5 GB/month compressed log storage

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Infrastructure as Code | PASS | All changes via Terraform; no manual K8s resource creation |
| II. Simplicity First | PASS | One new module per component (loki, alloy); Grafana module updated minimally |
| III. High Availability | ACCEPTED DEVIATION | Single Loki pod — no HA. Alloy buffers during restarts. Acceptable for homelab logs. |
| IV. Storage Patterns | PASS | WAL on emptyDir (ephemeral disk), chunks on MinIO (remote backup pattern matches litestream) |
| V. Security & Secrets | PASS | Dedicated MinIO user `loki` with scoped policy; credentials in K8s Secret |
| VI. Service Mesh | N/A | No Consul/Nomad involvement |

**HA Deviation Justification**: Loki monolithic HA requires distributed KV store (etcd/consul) for ingester ring coordination — significant complexity for no material benefit in a homelab. Alloy DaemonSet maintains its own WAL and retries, so brief Loki restarts result in delayed (not lost) log delivery. Logs are non-critical for service availability.

## Project Structure

### Documentation (this feature)

```text
specs/011-loki-migration/
├── plan.md                          # This file
├── spec.md                          # Feature specification
├── research.md                      # Phase 0 research findings
├── data-model.md                    # Phase 1 entity model + module structure
├── quickstart.md                    # Phase 1 implementation guide
├── contracts/
│   └── component-interfaces.md      # Phase 1 component interface contracts
├── checklists/
│   └── requirements.md              # Spec quality checklist (all pass)
└── tasks.md                         # Phase 2 output (/speckit.tasks — not yet created)
```

### Source Code (repository root)

```text
modules-k8s/
├── loki/                            # NEW
│   ├── main.tf                      # ConfigMap (loki.yaml), Deployment, Service
│   └── variables.tf                 # image_tag, minio_*, retention_period, etc.
├── alloy/                           # NEW
│   ├── main.tf                      # ConfigMap (config.alloy), DaemonSet,
│   │                                #   ServiceAccount, ClusterRole/Binding
│   └── variables.tf                 # image_tag, loki_url, namespace
└── grafana/
    ├── main.tf                      # UPDATED: add loki.yaml key to datasources ConfigMap
    └── variables.tf                 # UPDATED: add loki_url variable

kubernetes.tf                        # UPDATED: add k8s_loki + k8s_alloy modules,
                                     #   remove k8s_elk + k8s_elastic_agent modules

# REMOVED entirely (decommission phase):
modules-k8s/elk/                     # All resources deleted by Terraform
modules-k8s/elastic-agent/          # All resources deleted by Terraform
```

**Structure Decision**: Follows the existing pattern of one module per service (`main.tf` + `variables.tf`). No additional abstraction layers. Infrastructure-only — no application source code.

## Complexity Tracking

| Item | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| `loki.source.journal` for systemd logs | FR-007 requires host-level log collection | Could skip journal entirely; accepted as P2 user story, so worth including |
| Alloy `hostPath` for positions | Prevents log re-reads on pod restart | emptyDir would cause re-ingestion of all logs on every Alloy pod restart |
| Dedicated MinIO user | Constitution V (per-service credentials) | Using root MinIO credentials would violate security principle |
