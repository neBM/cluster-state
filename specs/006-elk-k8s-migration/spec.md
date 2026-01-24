# Feature Specification: ELK Stack Migration to Kubernetes Single-Node

**Feature Branch**: `006-elk-k8s-migration`  
**Created**: 2026-01-24  
**Status**: Draft  
**Input**: User description: "Convert elk to a single node cluster. One instance of elasticsearch node and one instance of kibana. Take time to research how to remove nodes from a cluster without data-loss. Migrate elk to k8s. Nomad should then be unused. Move elk data to gluster to allow moving the pod to any node."

## Overview

This feature migrates the existing 3-node Elasticsearch cluster and 2-instance Kibana deployment from Nomad to Kubernetes as a single-node cluster. The migration must preserve all existing log data and ensure the ELK stack can run on any cluster node by using GlusterFS-backed storage.

## Current State

- **Elasticsearch**: 3-node cluster running on Nomad across Hestia, Heracles, and Nyx
  - Data stored locally at `/var/lib/elasticsearch` on each node
  - Config stored at `/mnt/docker/elastic-{node}/config`
  - TLS enabled for transport and HTTP
- **Kibana**: 2 instances running on Nomad
  - Config stored at `/mnt/docker/elastic/kibana/config`
- **Nomad**: After this migration, Nomad will have no remaining workloads and can be decommissioned

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Safe Cluster Reduction (Priority: P1)

As a cluster administrator, I need to safely reduce the Elasticsearch cluster from 3 nodes to 1 node without losing any data, so that I can migrate to a simpler single-node architecture on Kubernetes.

**Why this priority**: Data preservation is the highest priority. If data is lost during migration, all other functionality is meaningless.

**Independent Test**: Can be tested by verifying document counts, index health, and data integrity before and after node removal.

**Acceptance Scenarios**:

1. **Given** a 3-node Elasticsearch cluster with data distributed across nodes, **When** I exclude nodes from allocation and wait for shard relocation, **Then** all shards are migrated to the remaining node with zero data loss
2. **Given** nodes have been excluded from voting configuration, **When** the excluded nodes are shut down, **Then** the remaining single node maintains cluster health status green (or yellow for indices with replica settings)
3. **Given** the cluster has been reduced to a single node, **When** I query for document counts across all indices, **Then** the counts match the pre-migration totals exactly

---

### User Story 2 - Data Migration to Shared Storage (Priority: P2)

As a cluster administrator, I need to move Elasticsearch data from local node storage to GlusterFS-backed shared storage, so that the Elasticsearch pod can be scheduled on any Kubernetes node.

**Why this priority**: Shared storage is required before K8s migration can occur, but only after the cluster is safely reduced to a single node.

**Independent Test**: Can be tested by copying data to GlusterFS, restarting Elasticsearch with the new data path, and verifying all indices are accessible.

**Acceptance Scenarios**:

1. **Given** Elasticsearch data exists on local disk, **When** I copy the data to GlusterFS storage, **Then** the data is accessible from any cluster node
2. **Given** Elasticsearch is configured to use GlusterFS storage, **When** the service starts, **Then** all indices are recognized and cluster health is restored
3. **Given** data resides on GlusterFS, **When** I access Kibana dashboards and run queries, **Then** all historical data is available and searchable

---

### User Story 3 - Kubernetes Deployment (Priority: P3)

As a cluster administrator, I need to deploy Elasticsearch and Kibana on Kubernetes with the same functionality as the Nomad deployment, so that all infrastructure is managed consistently through Kubernetes.

**Why this priority**: K8s deployment can only occur after data is safely on shared storage and cluster is reduced to single node.

**Independent Test**: Can be tested by deploying the K8s manifests and verifying service accessibility, log ingestion, and Kibana functionality.

**Acceptance Scenarios**:

1. **Given** the K8s Elasticsearch deployment is applied, **When** the pod starts, **Then** Elasticsearch is accessible via the existing external URL (es.brmartin.co.uk)
2. **Given** the K8s Kibana deployment is applied, **When** the pod starts, **Then** Kibana is accessible via the existing external URL (kibana.brmartin.co.uk)
3. **Given** both services are running on K8s, **When** Filebeat sends logs, **Then** new logs appear in Elasticsearch and are visible in Kibana
4. **Given** the K8s deployment is complete, **When** I restart the Elasticsearch pod, **Then** it can be scheduled on any node and data persists

---

### User Story 4 - Nomad Decommissioning (Priority: P4)

As a cluster administrator, I need to cleanly remove the ELK workloads from Nomad and deregister associated resources, so that Nomad can be fully decommissioned.

**Why this priority**: Cleanup only occurs after K8s migration is verified working.

**Independent Test**: Can be tested by stopping Nomad jobs and verifying no orphaned resources remain.

**Acceptance Scenarios**:

1. **Given** ELK is successfully running on K8s, **When** I stop the Nomad ELK job, **Then** no containers remain running on any node
2. **Given** Nomad ELK resources are removed from Terraform state, **When** I run terraform plan, **Then** no Nomad-related changes are pending
3. **Given** all Nomad workloads are stopped, **When** I check Nomad job status, **Then** no jobs are listed

---

### Edge Cases

- What happens if shard relocation fails during node removal?
  - The migration process must verify all shards are relocated before proceeding
  - Allocation exclusion must be validated before shutting down any node
  
- How does the system handle if GlusterFS becomes unavailable during migration?
  - Data copy must be verified with checksums before switching storage paths
  - Original data must be preserved until K8s deployment is verified working
  
- What happens if Elasticsearch fails to start with single-node configuration?
  - The `discovery.type: single-node` setting must be applied correctly
  - Bootstrap configuration must be cleared for single-node operation
  
- How is TLS certificate configuration handled in K8s?
  - Existing certificates must be migrated to K8s secrets
  - Certificate paths must be updated in the new configuration

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST safely relocate all shards from nodes being removed before shutdown
- **FR-002**: System MUST preserve all existing Elasticsearch indices and documents during migration
- **FR-003**: System MUST configure Elasticsearch as a single-node cluster using `discovery.type: single-node`
- **FR-004**: System MUST store Elasticsearch data on GlusterFS at `/storage/v/glusterfs_elasticsearch_data`
- **FR-005**: System MUST store Kibana configuration on GlusterFS at `/storage/v/glusterfs_kibana_config`
- **FR-006**: System MUST expose Elasticsearch via existing URL (es.brmartin.co.uk) with TLS
- **FR-007**: System MUST expose Kibana via existing URL (kibana.brmartin.co.uk)
- **FR-008**: System MUST migrate TLS certificates to Kubernetes secrets
- **FR-009**: System MUST migrate Kibana encryption keys to Kubernetes secrets via External Secrets Operator
- **FR-010**: System MUST remove ELK module from Nomad Terraform configuration
- **FR-011**: System MUST stop and purge the Nomad ELK job without data loss
- **FR-012**: Elasticsearch MUST continue to receive logs from existing Filebeat agents

### Key Entities

- **Elasticsearch Node**: Single-node cluster storing log data, requiring 2GB memory minimum, with TLS-enabled HTTP and transport layers
- **Kibana Instance**: Single instance for log visualization, connected to Elasticsearch with saved encryption keys for dashboards/reports
- **Elasticsearch Data**: Log indices with ILM policies, stored on shared storage for node portability
- **TLS Certificates**: Transport and HTTP certificates for Elasticsearch, CA certificate for Kibana

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero documents lost during migration (pre-migration count equals post-migration count for all indices)
- **SC-002**: Elasticsearch cluster health status is green or yellow (yellow acceptable for indices with replica settings > 0)
- **SC-003**: All existing Kibana dashboards and saved objects are accessible after migration
- **SC-004**: Log ingestion continues within 5 minutes of completing K8s deployment
- **SC-005**: Elasticsearch pod can be rescheduled to any cluster node and resume operation within 5 minutes
- **SC-006**: No Nomad jobs remain after migration is complete
- **SC-007**: External URLs (es.brmartin.co.uk, kibana.brmartin.co.uk) continue to work without client-side changes

## Assumptions

- The existing Elasticsearch cluster is healthy and all nodes are operational before migration begins
- GlusterFS has sufficient capacity to store all Elasticsearch data (currently ~23GB after ILM cleanup)
- Filebeat agents on all nodes are configured to send logs to the Elasticsearch hostname, not individual node IPs
- The External Secrets Operator is available for secret management in K8s
- TLS certificates can be copied from existing node configuration directories
- Single-node cluster is acceptable for this logging use case (no high-availability requirement)

## Dependencies

- GlusterFS storage must be accessible from all K8s nodes
- External Secrets Operator must be configured with Vault access for Kibana secrets
- Traefik IngressRoutes must be configured for external access
- Existing TLS certificates must be accessible for migration

## Out of Scope

- Setting up Elasticsearch high-availability or multi-node cluster in K8s
- Migrating to a different logging solution (e.g., Loki)
- Changing Filebeat configuration on client nodes
- Upgrading Elasticsearch version during migration
- Implementing new ILM policies or index templates
