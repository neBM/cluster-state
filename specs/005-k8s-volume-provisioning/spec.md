# Feature Specification: Kubernetes Volume Provisioning

**Feature Branch**: `005-k8s-volume-provisioning`  
**Created**: 2026-01-23  
**Status**: Draft  
**Input**: User description: "Currently, volumes are created by the nomad plugin. This means that k8s is unable to create volumes by itself without manually creating directories. Allow k8s to create volumes."

## Background

The cluster uses GlusterFS for distributed storage, accessed via NFS-Ganesha on all nodes. Currently:

- **Nomad services** use the democratic-csi plugin which automatically creates directories under `/storage/v/` when volumes are requested
- **Kubernetes services** use hostPath mounts directly to `/storage/v/glusterfs_<service>_<type>` directories
- These directories must be **manually created** before K8s deployments can start
- This creates operational friction when deploying new K8s services

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Deploy New K8s Service with Storage (Priority: P1)

As a cluster operator, I want to deploy a new Kubernetes service that requires persistent storage without having to SSH to nodes and manually create directories first.

**Why this priority**: This is the core problem - every new K8s service deployment currently requires manual intervention, breaking the declarative infrastructure-as-code workflow.

**Independent Test**: Deploy a new test service with a previously non-existent volume path and verify it starts successfully with persistent storage.

**Acceptance Scenarios**:

1. **Given** a new K8s module requiring storage at `/storage/v/glusterfs_newservice_data`, **When** I run `terraform apply`, **Then** the directory is automatically created and the pod starts successfully
2. **Given** a K8s deployment with a volume path that doesn't exist, **When** the pod is scheduled, **Then** the volume directory is created with appropriate permissions (0777, root:root)
3. **Given** a volume path that already exists, **When** a pod mounts it, **Then** existing data is preserved and no errors occur

---

### User Story 2 - Terraform-Managed Volume Lifecycle (Priority: P2)

As a cluster operator, I want volume directories to be managed through Terraform so that the infrastructure state accurately reflects what exists on the cluster.

**Why this priority**: Provides visibility into storage resources and enables proper cleanup when services are removed.

**Independent Test**: Create a volume via Terraform, verify it exists, then destroy the Terraform resource and verify the directory is removed (or retained based on policy).

**Acceptance Scenarios**:

1. **Given** a K8s module with storage requirements, **When** viewing Terraform state, **Then** I can see the volume resources defined
2. **Given** a volume managed by Terraform, **When** I run `terraform destroy` for that module, **Then** I am warned about data loss before deletion

---

### User Story 3 - Volume Naming Consistency (Priority: P3)

As a cluster operator, I want K8s volumes to follow the same naming convention as existing Nomad volumes so that storage organization remains consistent.

**Why this priority**: Maintains operational familiarity and allows existing backup/monitoring scripts to work without modification.

**Independent Test**: Create volumes for a new K8s service and verify they follow the `glusterfs_<service>_<type>` naming pattern.

**Acceptance Scenarios**:

1. **Given** a K8s service named "myapp" needing config and data storage, **When** volumes are created, **Then** paths are `/storage/v/glusterfs_myapp_config` and `/storage/v/glusterfs_myapp_data`
2. **Given** existing backup scripts that glob `/storage/v/glusterfs_*`, **When** K8s volumes are created, **Then** they are included in backups automatically

---

### Edge Cases

- What happens when volume creation fails due to NFS unavailability?
  - The pod should remain pending with a clear error message indicating storage is unavailable
- What happens when multiple pods try to create the same volume simultaneously?
  - Only one creation should succeed; others should detect the directory exists and proceed
- What happens when a volume path exists but has incorrect permissions?
  - The system should correct permissions to ensure pod access (or fail with clear error)
- What happens when disk space is exhausted on the GlusterFS volume?
  - Pod should fail to start with clear storage-related error message

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically create volume directories when K8s pods require storage that doesn't exist
- **FR-002**: System MUST create directories with permissions 0777 and ownership root:root (matching existing convention)
- **FR-003**: System MUST preserve existing data when mounting volumes that already contain data
- **FR-004**: System MUST follow naming convention `glusterfs_<service>_<type>` for new volumes
- **FR-005**: System MUST create volumes under the base path `/storage/v/` on all nodes
- **FR-006**: Volume creation MUST be idempotent - repeated attempts with same path should succeed without error
- **FR-007**: System MUST support creating volumes on any node where the pod may be scheduled (Hestia, Heracles, or Nyx)

### Key Entities

- **Volume**: A directory on GlusterFS storage accessible via NFS mount at `/storage/v/`
  - Attributes: path, permissions, ownership, associated service
- **StorageClass** (if using dynamic provisioning): Defines how volumes are created
  - Attributes: provisioner, reclaim policy, volume binding mode

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: New K8s services can be deployed with storage in a single `terraform apply` without manual SSH intervention
- **SC-002**: Volume creation completes within 30 seconds of pod scheduling
- **SC-003**: 100% of existing K8s services continue to function after implementing this change (no breaking changes)
- **SC-004**: Volume naming remains consistent with existing pattern, allowing backup scripts to work unchanged

## Assumptions

- NFS-Ganesha is running and healthy on all nodes (prerequisite)
- GlusterFS volume is mounted at `/storage/v/` on all nodes
- The K8s cluster has appropriate node access to create directories on the NFS mount
- All nodes have the same NFS mount configuration

## Out of Scope

- Automatic volume deletion when services are removed (data retention is preferred)
- Volume size limits or quotas (GlusterFS doesn't support per-directory quotas)
- Volume encryption (not currently used in the cluster)
- Multi-cluster volume sharing
