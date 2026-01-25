# Feature Specification: Elasticsearch Multi-Node Cluster

**Feature Branch**: `009-es-multi-node-cluster`  
**Created**: 2026-01-25  
**Status**: Draft  
**Input**: User description: "Convert ES to a multi-node cluster. Two data nodes and one tiebreaker node. Kibana remains unaffected (no pinning, no replicas). Retention policies unchanged. Snapshot settings unchanged. No data loss. Downtime acceptable."

## Overview

Convert the existing single-node Elasticsearch deployment to a highly available multi-node cluster following Elastic's recommended "two nodes plus tiebreaker" architecture. This eliminates the GlusterFS storage dependency, improves I/O performance by using local storage on each node, and provides fault tolerance through shard replication.

### Current State

- Single ES node running on Nyx (8GB RAM node, severely overloaded)
- Data stored on GlusterFS via NFS mount (slow I/O, high CPU from storage layer)
- 16GB of index data
- 188 shards across various indices
- Frequent OOM restarts and high flush queue due to storage bottleneck

### Target Architecture

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│     Hestia      │  │    Heracles     │  │       Nyx       │
│     (amd64)     │  │     (arm64)     │  │     (arm64)     │
│     16GB RAM    │  │     16GB RAM    │  │     8GB RAM     │
├─────────────────┤  ├─────────────────┤  ├─────────────────┤
│ ES Data Node    │  │ ES Data Node    │  │ ES Voting-only  │
│ master,data     │  │ master,data     │  │ master          │
│ ingest,ml       │  │ ingest          │  │ (tiebreaker)    │
│                 │  │                 │  │                 │
│ Local storage   │  │ Local storage   │  │ No data storage │
│ ~50GB           │  │ ~50GB           │  │ Minimal memory  │
└─────────────────┘  └─────────────────┘  └─────────────────┘
        │                    │                    │
        └────────────────────┼────────────────────┘
                             │
                    K8s Service (load balanced)
                             │
                             ▼
                    ┌─────────────────┐
                    │     Kibana      │
                    │  (unchanged)    │
                    └─────────────────┘
```

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cluster Survives Single Node Failure (Priority: P1)

As a cluster operator, I need the Elasticsearch cluster to continue operating when any single node fails, so that log ingestion and search remain available during hardware failures or maintenance.

**Why this priority**: High availability is the primary goal of this migration. The cluster must tolerate single-node failures without data loss or service interruption.

**Independent Test**: Can be fully tested by stopping one data node and verifying the cluster remains GREEN with all data accessible.

**Acceptance Scenarios**:

1. **Given** a healthy 3-node cluster with replicated shards, **When** one data node is stopped, **Then** the cluster status transitions to YELLOW (not RED), all indices remain readable, and writes continue to succeed.

2. **Given** one data node is offline, **When** the node returns to the cluster, **Then** shard replication resumes automatically and cluster returns to GREEN status.

3. **Given** a healthy 3-node cluster, **When** the tiebreaker node fails, **Then** the cluster remains operational with both data nodes (no split-brain, master election succeeds).

---

### User Story 2 - Improved I/O Performance (Priority: P1)

As a cluster operator, I need Elasticsearch to use local storage instead of network-attached GlusterFS storage, so that indexing and search performance improve and node resource consumption decreases.

**Why this priority**: The current GlusterFS storage is causing severe I/O bottlenecks (95% CPU on Nyx, 17+ pending flushes, frequent OOM kills). Local storage eliminates this bottleneck.

**Independent Test**: Can be verified by measuring indexing throughput and flush queue depth before and after migration.

**Acceptance Scenarios**:

1. **Given** the new multi-node cluster with local storage, **When** Elastic Agent sends log data at normal rates, **Then** the flush queue remains consistently below 5 (vs current 17+).

2. **Given** the new multi-node cluster, **When** checking node resource usage, **Then** GlusterFS processes no longer consume significant CPU on ES nodes.

---

### User Story 3 - Zero Data Loss Migration (Priority: P1)

As a cluster operator, I need all existing indices and data preserved during the migration, so that historical logs and dashboards remain available.

**Why this priority**: Data loss would be unacceptable. The migration must preserve all 16GB of existing index data.

**Independent Test**: Can be verified by comparing index counts and document counts before and after migration.

**Acceptance Scenarios**:

1. **Given** a snapshot of the current single-node cluster, **When** the multi-node cluster is deployed, **Then** all indices can be restored with matching document counts.

2. **Given** the migration is complete, **When** querying historical logs in Kibana, **Then** all previously-indexed data is accessible.

---

### User Story 4 - Kibana Continues Working (Priority: P1)

As a user, I need Kibana to continue working throughout and after the migration, so that I can access dashboards and search logs.

**Why this priority**: Kibana is the primary user interface; it must remain functional with no configuration changes.

**Independent Test**: Can be verified by accessing Kibana and running searches before, during (after brief downtime), and after migration.

**Acceptance Scenarios**:

1. **Given** the multi-node cluster is operational, **When** Kibana connects to the ES service, **Then** all existing dashboards, saved searches, and visualizations work without modification.

2. **Given** Kibana is configured with the ES service endpoint, **When** one ES data node fails, **Then** Kibana automatically routes requests to the healthy node via the K8s service.

---

### User Story 5 - Existing Integrations Continue Working (Priority: P2)

As a cluster operator, I need Elastic Agent, Fleet Server, and existing snapshot configurations to continue working after migration.

**Why this priority**: These integrations provide ongoing value but can tolerate brief reconfiguration if needed.

**Independent Test**: Can be verified by checking Elastic Agent connectivity and snapshot job execution after migration.

**Acceptance Scenarios**:

1. **Given** the multi-node cluster is operational, **When** Elastic Agent sends data, **Then** logs appear in the expected data streams.

2. **Given** existing snapshot repository configuration, **When** snapshot jobs run, **Then** snapshots complete successfully to the same MinIO destination.

---

### Edge Cases

- What happens when both data nodes fail simultaneously? The cluster becomes unavailable - this is expected behavior as the tiebreaker cannot serve data.
- How does the cluster handle network partitions between nodes? The tiebreaker provides quorum, preventing split-brain scenarios.
- What happens if local storage fills up on one node? Shard allocation moves to the other node, alerts should fire on disk pressure.
- How does rolling restart work? One node at a time, cluster stays available throughout.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Cluster MUST consist of exactly three nodes: two data nodes with master eligibility and one voting-only tiebreaker node.
- **FR-002**: Data nodes MUST use local storage (local-path StorageClass or hostPath to local disk) instead of GlusterFS/NFS.
- **FR-003**: All indices MUST have at least one replica, ensuring data exists on both data nodes.
- **FR-004**: The tiebreaker node MUST have minimal resource requirements (256Mi memory or less) and MUST NOT hold any data.
- **FR-005**: Each data node MUST be pinned to a specific physical host (Hestia and Heracles) via node affinity.
- **FR-006**: The tiebreaker node MUST run on the remaining host (Nyx) via node affinity.
- **FR-007**: All nodes MUST be able to discover each other via Kubernetes DNS.
- **FR-008**: The ES HTTP service MUST load-balance across both data nodes for client connections.
- **FR-009**: Existing ILM policies, retention settings, and data stream configurations MUST be preserved.
- **FR-010**: Existing snapshot repository and schedule MUST continue functioning unchanged.
- **FR-011**: Kibana configuration MUST remain unchanged (same service endpoint).
- **FR-012**: Migration MUST preserve all existing index data (zero data loss).
- **FR-013**: Cluster MUST use the same ES version (9.2.3) as current deployment.
- **FR-014**: Transport layer communication between nodes MUST be TLS-encrypted.
- **FR-015**: HTTP layer MUST maintain current TLS configuration.

### Key Entities

- **Data Node**: Elasticsearch node with roles `master`, `data`, `ingest`. Holds primary and replica shards. Two instances, one on Hestia and one on Heracles.
- **Tiebreaker Node**: Elasticsearch node with role `master` only (voting_only). Participates in master elections but holds no data. One instance on Nyx.
- **Shard Replica**: Copy of each primary shard stored on the other data node. Provides fault tolerance and read scaling.
- **K8s Headless Service**: For node discovery via DNS (cluster formation).
- **K8s ClusterIP Service**: For client connections (Kibana, Elastic Agent) with load balancing.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Cluster remains GREEN status during normal operation with all three nodes healthy.
- **SC-002**: Cluster maintains YELLOW status (not RED) when any single node is unavailable.
- **SC-003**: Flush queue depth stays below 5 during normal indexing load (vs current 17+).
- **SC-004**: Node CPU usage on data nodes stays below 60% during normal operation (vs current 95% on Nyx).
- **SC-005**: All existing indices are accessible after migration with matching document counts.
- **SC-006**: Kibana connects successfully without configuration changes.
- **SC-007**: Snapshot jobs complete successfully to existing MinIO repository.
- **SC-008**: Tiebreaker node uses less than 300Mi memory.
- **SC-009**: Shard recovery completes within 30 minutes of a data node rejoining the cluster.
- **SC-010**: No data loss - index document counts match pre-migration counts.

## Assumptions

- **A-001**: Local storage on Hestia and Heracles has sufficient capacity (50GB+ free on each) for ES data.
- **A-002**: Network bandwidth between nodes is sufficient for shard replication (1Gbps LAN).
- **A-003**: Existing TLS certificates can be shared across all nodes or new per-node certificates can be generated.
- **A-004**: K3s local-path provisioner is available or hostPath volumes can be used for local storage.
- **A-005**: Downtime during migration is acceptable (estimated 15-30 minutes for snapshot/restore approach).
- **A-006**: The arm64 nodes (Heracles, Nyx) can run ES - official ES images support multi-arch.

## Out of Scope

- Kibana high availability (remains single instance, no changes)
- Changes to retention policies or ILM configurations
- Changes to snapshot schedules or destinations
- Adding additional data nodes beyond the two specified
- Cross-cluster replication or remote cluster configuration
- Changing the ES version

## Dependencies

- **D-001**: Pre-migration snapshot to MinIO for data preservation
- **D-002**: Local storage availability on Hestia and Heracles
- **D-003**: Updated Terraform ELK module to support multi-node configuration

## Migration Approach

1. Take a full snapshot of current single-node cluster to MinIO
2. Verify snapshot integrity
3. Stop the current single-node ES StatefulSet
4. Deploy the new 3-node cluster with empty local storage
5. Configure snapshot repository on the new cluster
6. Restore snapshot to new cluster
7. Verify all indices and data
8. Update any necessary service endpoints
9. Verify Kibana and Elastic Agent connectivity
10. Remove old GlusterFS data directory (after validation period)
