# Feature Specification: Nomad to Kubernetes Migration (Proof of Concept)

**Feature Branch**: `003-nomad-to-kubernetes`  
**Created**: 2026-01-21  
**Status**: Draft  
**Input**: User description: "Given our recent findings with Nomad limiting features to enterprise users and this deployment is a prime learning ground for me, lets explore replacing nomad with kubernetes so we can use Vertical Pod Autoscale."

## Background & Motivation

The current homelab cluster runs on HashiCorp Nomad with Consul for service mesh. Recent investigation (see `002-nomad-vertical-autoscaling`) revealed that Vertical Pod Autoscaling equivalent ("Dynamic Application Sizing") is an Enterprise-only feature in Nomad.

This migration serves dual purposes:
1. **Learning opportunity**: Gain hands-on Kubernetes experience in a real environment
2. **Feature access**: Unlock capabilities like Vertical Pod Autoscaler that are freely available in Kubernetes

## Scope: Proof of Concept

**This specification covers a proof-of-concept migration only.** The goal is to validate that Kubernetes is a viable replacement for Nomad by migrating a minimal number of services (2-3) that demonstrate key capabilities:

- One stateless service (validates basic deployment, ingress, VPA)
- One stateful service with persistent storage (validates storage migration, data integrity)
- Service-to-service communication via mesh (validates service mesh functionality)

**Full migration of all services is explicitly out of scope.** If the PoC is successful, a separate specification will be created for the complete migration.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - PoC Service Deployment (Priority: P1)

As a cluster operator, I want to deploy 2-3 proof-of-concept services to Kubernetes so that I validate the migration approach is viable before committing to a full migration.

**Why this priority**: Proving feasibility with minimal risk is essential. The PoC services should demonstrate core capabilities without disrupting critical production services.

**Independent Test**: Can be tested by deploying a low-risk service to Kubernetes and verifying it's accessible and functional.

**Acceptance Scenarios**:

1. **Given** a Kubernetes cluster running alongside Nomad, **When** I deploy a PoC service, **Then** it runs successfully without affecting Nomad workloads.
2. **Given** a PoC service on Kubernetes, **When** I access it via its URL, **Then** it responds correctly with valid TLS.
3. **Given** issues with a PoC service, **When** I need to revert, **Then** I can disable it without impacting other services.

---

### User Story 2 - Vertical Pod Autoscaling (Priority: P2)

As a cluster operator, I want services to automatically adjust their CPU and memory allocations based on actual usage so that resources are efficiently utilized without manual tuning.

**Why this priority**: This is the primary motivator for the migration. Without VPA, the operator must manually monitor and adjust resource allocations.

**Independent Test**: Can be tested by deploying a service with VPA enabled and observing automatic resource adjustments over a 24-hour period.

**Acceptance Scenarios**:

1. **Given** a service with VPA enabled, **When** the service consistently uses less memory than allocated, **Then** VPA recommends or applies a lower memory request.
2. **Given** a service experiencing increased load, **When** resource usage exceeds current requests, **Then** VPA recommends or applies higher resource requests.
3. **Given** VPA recommendations, **When** I review them, **Then** I can see the recommended CPU and memory values with confidence intervals.

---

### User Story 3 - Persistent Storage (Priority: P2)

As a cluster operator, I want at least one stateful service with persistent storage running on Kubernetes so that I validate the storage provisioning and data integrity patterns before a broader migration.

**Why this priority**: Data integrity is critical. Proving persistent storage works in the PoC de-risks future migrations of services like GitLab, Nextcloud, and databases.

**Independent Test**: Can be tested by deploying a stateful PoC service, writing data, restarting the pod, and verifying data persists.

**Acceptance Scenarios**:

1. **Given** a stateful PoC service on Kubernetes, **When** the pod restarts, **Then** persistent data is retained.
2. **Given** a service using SQLite with Litestream backup, **When** deployed to Kubernetes, **Then** Litestream replicates to MinIO successfully.
3. **Given** a persistent volume, **When** I verify the data, **Then** I can confirm integrity through checksums or application validation.

---

### User Story 4 - Infrastructure as Code Continuity (Priority: P3)

As a cluster operator, I want to manage Kubernetes resources using Terraform so that I maintain the same GitOps workflow currently used with Nomad.

**Why this priority**: Preserving the existing workflow reduces learning curve and maintains operational consistency. Terraform already manages the Nomad deployment.

**Independent Test**: Can be tested by defining a Kubernetes deployment in Terraform and successfully applying it.

**Acceptance Scenarios**:

1. **Given** a service definition in Terraform, **When** I run `terraform apply`, **Then** the service is deployed to Kubernetes.
2. **Given** changes to a service definition, **When** I run `terraform plan`, **Then** I see the expected changes before applying.
3. **Given** the need to destroy a service, **When** I remove it from Terraform and apply, **Then** the service is cleanly removed from Kubernetes.

---

### User Story 5 - Ingress and TLS (Priority: P3)

As a cluster operator, I want external traffic to reach Kubernetes services via HTTPS so that the current user experience is maintained.

**Why this priority**: All services are currently accessible via `*.brmartin.co.uk` with TLS. This must continue working.

**Independent Test**: Can be tested by accessing a migrated service via its existing URL and verifying TLS works correctly.

**Acceptance Scenarios**:

1. **Given** a service migrated to Kubernetes, **When** I access it via `https://service.brmartin.co.uk`, **Then** I reach the service with a valid TLS certificate.
2. **Given** the existing Traefik deployment, **When** services run on Kubernetes, **Then** Traefik can route to them (either directly or via migration to Kubernetes ingress).

---

### User Story 6 - Service Mesh (Priority: P3)

As a cluster operator, I want services to communicate securely via a service mesh so that inter-service traffic is encrypted and I can implement traffic policies.

**Why this priority**: The current Nomad deployment uses Consul Connect for service mesh with transparent proxy. Maintaining equivalent functionality ensures secure service-to-service communication.

**Independent Test**: Can be tested by deploying two services that communicate via the mesh and verifying mTLS encryption is active.

**Acceptance Scenarios**:

1. **Given** two services in the mesh, **When** they communicate, **Then** traffic is encrypted via mutual TLS.
2. **Given** a service mesh policy, **When** I restrict traffic between services, **Then** unauthorized communication is blocked.
3. **Given** services in the mesh, **When** I observe traffic, **Then** I can see metrics and tracing data for debugging.

---

### User Story 7 - IAC Repository for Kubernetes (Priority: P2)

As a cluster operator, I want this IAC repository (cluster-state) to support deploying PoC services to Kubernetes so that I establish the patterns for future migrations.

**Why this priority**: The current repository structure uses Terraform modules with Nomad jobspecs. Adding Kubernetes support alongside Nomad enables gradual transition.

**Independent Test**: Can be tested by creating a Kubernetes module in this repository and deploying it via `terraform apply`.

**Acceptance Scenarios**:

1. **Given** a Kubernetes service definition in this repository, **When** I run `terraform apply`, **Then** the PoC service is deployed to the Kubernetes cluster.
2. **Given** the existing module structure, **When** I add a Kubernetes module, **Then** it coexists with Nomad modules without conflict.
3. **Given** secrets in Vault, **When** deploying a PoC service to Kubernetes, **Then** secrets are accessible to the workload.

---

### Edge Cases

- What happens when a pod is evicted during VPA scaling? (Brief service interruption expected)
- How does the cluster handle mixed Nomad/Kubernetes workloads during transition? (Coexistence period)
- What happens if GlusterFS is incompatible with Kubernetes CSI? (May need alternative storage solution)
- How are services discovered during the hybrid period? (DNS or shared service mesh)
- What happens when a service mesh sidecar fails? (Service may lose connectivity)
- How do services outside the mesh communicate with meshed services? (Ingress gateway or mesh bypass)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: PoC MUST deploy 2-3 services to Kubernetes to validate the migration approach
- **FR-002**: PoC services MUST be accessible via HTTPS with valid TLS certificates
- **FR-003**: At least one PoC service MUST use persistent storage to validate storage patterns
- **FR-004**: Vertical Pod Autoscaler MUST be deployed and provide recommendations for PoC services
- **FR-005**: PoC services MUST be managed via Terraform in this repository
- **FR-006**: Kubernetes cluster MUST coexist with Nomad without disrupting existing services
- **FR-007**: PoC MUST work with the existing 3-node cluster (Hestia amd64, Heracles arm64, Nyx arm64)
- **FR-008**: PoC services MUST support mixed architecture nodes (amd64 and arm64)
- **FR-009**: Cluster MUST include a service mesh demonstrating mTLS between PoC services
- **FR-010**: This IAC repository MUST support Kubernetes deployments alongside existing Nomad modules
- **FR-011**: At least one Kubernetes module MUST be created following established patterns
- **FR-012**: At least one PoC service MUST demonstrate Vault secret injection

### Key Entities

- **Kubernetes Cluster**: The container orchestration platform replacing Nomad
- **Workload**: A service or application deployed to the cluster (Deployment, StatefulSet, etc.)
- **Persistent Volume**: Storage that survives pod restarts, replacing Nomad CSI volumes
- **Vertical Pod Autoscaler**: Component that adjusts pod resource requests based on usage
- **Ingress**: Entry point for external traffic, replacing Traefik Consul Catalog integration
- **Service Mesh**: Infrastructure layer for secure service-to-service communication, replacing Consul Connect
- **IAC Repository**: This cluster-state repository containing Terraform modules for all service deployments

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 2-3 PoC services running successfully on Kubernetes
- **SC-002**: Vertical Pod Autoscaler provides resource recommendations for PoC services within 24 hours
- **SC-003**: At least one stateful PoC service demonstrates persistent storage with data retained across pod restarts
- **SC-004**: PoC services accessible via HTTPS with valid TLS certificates
- **SC-005**: Nomad services continue running unaffected during PoC deployment
- **SC-006**: This repository successfully deploys PoC services to Kubernetes via `terraform apply`
- **SC-007**: Cluster operator gains practical Kubernetes experience (subjective but primary goal)
- **SC-008**: Service mesh enables mTLS between at least 2 PoC services
- **SC-009**: At least one PoC service uses Vault secrets
- **SC-010**: PoC validates that full migration is feasible (go/no-go decision documented)

## Assumptions

1. The existing 3-node cluster has sufficient resources to run Kubernetes control plane alongside Nomad workloads
2. K3s (lightweight Kubernetes) is suitable for homelab scale - full Kubernetes would be excessive
3. GlusterFS can be accessed from Kubernetes via NFS or a Kubernetes-compatible CSI driver
4. Traefik can route to Kubernetes services (either existing Traefik or K3s built-in)
5. PoC services are low-risk and can tolerate experimentation (not Plex, GitLab, Nextcloud initially)
6. Nomad continues running all production services during PoC - no production migrations in this phase

## PoC Phases (Informational)

### Phase 1: Foundation
- Install K3s on existing nodes alongside Nomad
- Configure basic networking and storage access
- Deploy service mesh (e.g., Cilium, Linkerd, or Istio)
- Deploy Vertical Pod Autoscaler
- Update this repository with Kubernetes provider configuration

### Phase 2: First PoC Service
- Configure ingress for Kubernetes services
- Set up persistent volume provisioning
- Configure Vault integration for secrets
- Deploy first stateless PoC service via Terraform module
- Validate VPA recommendations

### Phase 3: Stateful PoC Service
- Deploy a stateful PoC service with persistent storage
- Validate data persistence across pod restarts
- Demonstrate Litestream or similar backup pattern if applicable

### Phase 4: Service Mesh Validation
- Deploy a second PoC service that communicates with the first
- Enable and validate mTLS between services
- Document service mesh configuration patterns

### Phase 5: PoC Evaluation
- Review all success criteria
- Document lessons learned, challenges, and blockers
- Make go/no-go recommendation for full migration
- If go: Create separate specification for full migration

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| K3s installation disrupts Nomad | High | Test installation process, have rollback plan |
| Resource constraints running both orchestrators | Medium | Monitor closely, PoC services are lightweight |
| Learning curve slows progress | Low | This is acceptable - learning is a primary goal |
| GlusterFS incompatibility with K8s | Medium | Evaluate alternative storage (Longhorn, local-path) early |
| Service mesh adds complexity | Medium | Start with lightweight mesh, document learnings |
| PoC succeeds but full migration proves harder | Low | PoC specifically tests challenging patterns (storage, mesh) |

## Out of Scope

- **Full migration of all services** - this is a proof-of-concept only
- Migrating production/critical services (Plex, GitLab, Nextcloud, etc.) - PoC uses low-risk services
- Migrating to managed Kubernetes (EKS, GKE, AKS) - staying on-premise
- Implementing Horizontal Pod Autoscaler (may be future enhancement)
- Multi-cluster federation
- Advanced service mesh features (circuit breaking, canary deployments) - basic mTLS only
- Decommissioning Nomad - remains running for all production services

## PoC Service Candidates

The following services are good candidates for the PoC due to low risk and ability to demonstrate key capabilities:

| Service | Type | Demonstrates |
|---------|------|--------------|
| Overseerr | Stateful (SQLite + Litestream) | Storage, VPA, Litestream pattern |
| Whoami/echo-server | Stateless | Basic deployment, ingress, VPA |
| A second simple service | Stateless | Service mesh mTLS communication |

*Note: Overseerr was recently migrated to Nomad, making it a good candidate as the process is fresh and rollback is straightforward.*
