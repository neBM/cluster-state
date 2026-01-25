# Implementation Plan: Elasticsearch Multi-Node Cluster

**Branch**: `009-es-multi-node-cluster` | **Date**: 2026-01-25 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-es-multi-node-cluster/spec.md`

## Summary

Convert the existing single-node Elasticsearch deployment to a highly available 3-node cluster (two data nodes + one voting-only tiebreaker). This eliminates the GlusterFS storage bottleneck by using local storage on each data node, provides fault tolerance through shard replication, and significantly improves I/O performance (target: flush queue <5 vs current 17+).

## Technical Context

**Language/Version**: HCL (Terraform 1.x), Kubernetes YAML via Terraform providers  
**Primary Dependencies**: Terraform kubernetes/kubectl providers, Elasticsearch 9.2.3, K3s 1.34+  
**Storage**: local-path StorageClass for ES data nodes (50GB each), no storage for tiebreaker  
**Testing**: Manual validation - cluster health, shard replication, Kibana connectivity  
**Target Platform**: K3s cluster (Hestia amd64, Heracles/Nyx arm64)  
**Project Type**: Infrastructure-as-Code (Terraform module modification)  
**Performance Goals**: Flush queue depth <5, node CPU <60%, cluster GREEN status  
**Constraints**: Zero data loss during migration, single-node failure tolerance required  
**Scale/Scope**: 3 ES nodes, ~16GB index data, 188 shards replicated to 2 data nodes

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Pre-Design Check (Phase 0 Gate)

| Principle | Status | Notes |
|-----------|--------|-------|
| **I. Infrastructure as Code** | PASS | All changes via Terraform, no manual infrastructure changes |
| **II. Simplicity First** | PASS | Single module modification, explicit node configuration |
| **III. High Availability by Design** | PASS | Primary goal - tolerates single node failure, no SPOF |
| **IV. Storage Patterns** | PASS | Moving FROM GlusterFS TO local storage (better for ES) |
| **V. Security & Secrets** | PASS | TLS transport between nodes, existing secrets maintained |
| **VI. Service Mesh Patterns** | N/A | ES uses direct TCP transport, not Consul mesh |

**Gate Status**: PASS - Proceeded to Phase 0

### Post-Design Check (Phase 1 Gate)

| Principle | Status | Notes |
|-----------|--------|-------|
| **I. Infrastructure as Code** | PASS | All K8s resources defined in Terraform (StatefulSets, Services, ConfigMaps) |
| **II. Simplicity First** | PASS | Two StatefulSets + services; explicit node affinity; no abstraction layers |
| **III. High Availability by Design** | PASS | 3 master-eligible nodes, shard replication, voting-only tiebreaker prevents split-brain |
| **IV. Storage Patterns** | PASS | local-path with Retain policy for data nodes; no persistent storage for tiebreaker |
| **V. Security & Secrets** | PASS | Per-node TLS certs via Secrets; transport layer encrypted; existing keystore reused |
| **VI. Service Mesh Patterns** | N/A | ES transport layer uses direct TCP; not mesh-integrated |

**Design Validation**:
- Separate StatefulSets for data/tiebreaker: Justified (different resource profiles)
- Custom StorageClass (local-path-retain): Required (Retain policy for data safety)
- Node affinity: Required (deterministic placement for local storage)

**Gate Status**: PASS - Ready for Phase 2 task generation

## Project Structure

### Documentation (this feature)

```text
specs/009-es-multi-node-cluster/
├── plan.md              # This file
├── research.md          # Phase 0 output - ES clustering research
├── data-model.md        # Phase 1 output - Node and shard topology
├── quickstart.md        # Phase 1 output - Migration steps
├── contracts/           # Phase 1 output - ES cluster configuration
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
modules-k8s/elk/
├── main.tf              # MODIFIED: Multi-node ES StatefulSets, services, ingress
├── variables.tf         # MODIFIED: New vars for multi-node config
├── secrets.tf           # UNCHANGED: Kibana secrets (no ES changes)
└── versions.tf          # UNCHANGED: Provider versions
```

**Structure Decision**: Modify existing `modules-k8s/elk/` module. The ES configuration in `main.tf` changes from a single StatefulSet to multiple StatefulSets (or a multi-replica StatefulSet with unique node configs). Variables extend for node-specific settings.

## Complexity Tracking

> **No Constitution Check violations - all principles pass.**
