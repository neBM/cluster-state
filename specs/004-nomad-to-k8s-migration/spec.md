# Feature Specification: Nomad to Kubernetes Full Migration

**Feature Branch**: `004-nomad-to-k8s-migration`  
**Created**: 2026-01-22  
**Status**: Draft  
**Input**: User description: "Migrate all Nomad services to Kubernetes. Services must be accessible from the same addresses. Use existing data. Delete K8s overseerr PoC and migrate Nomad overseerr properly. Use service mesh where possible. Exclude media-centre (peak-time)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Seamless Service Access (Priority: P1)

As a user of the cluster services, I can access all services at their existing URLs without any change to bookmarks, DNS, or client configurations after the migration is complete.

**Why this priority**: Zero user impact is the primary requirement. If URLs change or services become inaccessible, the migration has failed regardless of technical implementation quality.

**Independent Test**: Access each service URL (e.g., `git.brmartin.co.uk`, `cloud.brmartin.co.uk`) before and after migration - response should be identical.

**Acceptance Scenarios**:

1. **Given** a service is migrated to K8s, **When** a user accesses its original URL, **Then** the service responds identically to the Nomad version
2. **Given** all services except media-centre are migrated, **When** a user accesses any migrated service, **Then** there is no indication the underlying platform changed
3. **Given** a service uses OAuth authentication (e.g., `searx.brmartin.co.uk`), **When** a user accesses it after migration, **Then** OAuth flow works identically

---

### User Story 2 - Data Continuity (Priority: P1)

As a user of stateful services (GitLab, Nextcloud, Vaultwarden, etc.), I can access all my existing data, configurations, and history after the migration without any data loss.

**Why this priority**: Data loss would be catastrophic. Services must use the same underlying storage (GlusterFS CSI volumes, litestream backups) to ensure continuity.

**Independent Test**: Verify specific data artifacts exist post-migration (e.g., GitLab repos, Nextcloud files, Vaultwarden passwords).

**Acceptance Scenarios**:

1. **Given** GitLab is migrated, **When** I access my repositories, **Then** all commits, issues, and CI pipelines are present
2. **Given** Nextcloud is migrated, **When** I browse my files, **Then** all files and shares are intact
3. **Given** Vaultwarden is migrated, **When** I log in, **Then** all passwords and secure notes are accessible
4. **Given** Matrix is migrated, **When** I open Element, **Then** all rooms and message history are present

---

### User Story 3 - Service Mesh Integration (Priority: P2)

As a cluster operator, migrated services communicate securely via the Cilium service mesh where applicable, providing encrypted inter-service communication.

**Why this priority**: Security enhancement over Nomad's Consul Connect. Not blocking for migration but improves security posture.

**Independent Test**: Use Hubble UI to verify mTLS connections between services that communicate (e.g., litestream to minio, services to keycloak).

**Acceptance Scenarios**:

1. **Given** a service backs up via litestream, **When** it connects to MinIO, **Then** the connection is visible in Hubble as encrypted
2. **Given** services use Keycloak for SSO, **When** they authenticate, **Then** connections use the service mesh

---

### User Story 4 - Nomad Decommission (Priority: P3)

As a cluster operator, I can decommission Nomad jobs after successful K8s migration, freeing up cluster resources.

**Why this priority**: Resource cleanup is the final step after all services are verified working.

**Independent Test**: Stop Nomad jobs one by one after verifying K8s equivalents are working.

**Acceptance Scenarios**:

1. **Given** a service is verified working on K8s, **When** I stop its Nomad job, **Then** the service continues working via K8s
2. **Given** all services except media-centre are migrated, **When** Nomad jobs are stopped, **Then** cluster resource usage decreases

---

### Edge Cases

- What happens if a K8s pod fails during migration while Nomad job is still running? (Coordinate by stopping Nomad job before starting K8s workload to avoid storage conflicts)
- How do we handle services with complex Consul intentions? (Replicate with CiliumNetworkPolicy)
- What happens to periodic jobs like renovate and restic-backup? (Migrate as K8s CronJobs)
- How do we handle CSI plugin services? (These remain on Nomad as they're cluster infrastructure)

## Requirements *(mandatory)*

### Functional Requirements

#### Service Migration

- **FR-001**: Each migrated service MUST be accessible at its original URL (e.g., `git.brmartin.co.uk`, `cloud.brmartin.co.uk`)
- **FR-002**: Each migrated service MUST use the same underlying storage volumes as the Nomad version
- **FR-003**: Services requiring OAuth middleware MUST continue using the existing oauth2-proxy
- **FR-004**: The existing K8s overseerr PoC instance MUST be deleted before migrating the Nomad overseerr
- **FR-005**: Media-centre job MUST remain on Nomad (explicitly excluded from migration)

#### Storage & Data

- **FR-006**: Services using GlusterFS CSI volumes MUST mount the same volume paths in K8s
- **FR-007**: Services using litestream MUST use the same MinIO buckets for backup continuity
- **FR-008**: Services using SQLite MUST use ephemeral disk with litestream (matching Nomad pattern)
- **FR-009**: TLS secrets MUST be available in the appropriate K8s namespaces

#### Networking

- **FR-010**: External Traefik MUST route to K8s Traefik for migrated services
- **FR-011**: Services MUST be able to reach Consul DNS for any remaining Nomad services (e.g., media-centre)
- **FR-012**: K8s services MUST use Cilium service mesh for inter-pod communication where applicable

#### Infrastructure Jobs

- **FR-013**: CSI plugin jobs (glusterfs-controller, glusterfs-nodes, martinibar-*) MUST remain on Nomad
- **FR-014**: Traefik (external) MUST remain as Docker container on Hestia
- **FR-015**: Periodic jobs (renovate, restic-backup) MUST be migrated as K8s CronJobs

### Services to Migrate

| Service | URL(s) | Storage Type | Special Considerations |
|---------|--------|--------------|------------------------|
| appflowy | docs.brmartin.co.uk | GlusterFS | Multiple containers (gotrue, appflowy) |
| elk | es.brmartin.co.uk, kibana.brmartin.co.uk | GlusterFS | Elasticsearch cluster |
| gitlab | git.brmartin.co.uk, registry.brmartin.co.uk | GlusterFS | Complex multi-component |
| gitlab-runner | N/A (internal) | None | Docker-in-Docker |
| keycloak | sso.brmartin.co.uk | GlusterFS | SSO provider |
| matrix | matrix.brmartin.co.uk, element.brmartin.co.uk, cinny.brmartin.co.uk | GlusterFS | Multiple frontends |
| minio | minio.brmartin.co.uk | GlusterFS | Critical for litestream |
| nextcloud | cloud.brmartin.co.uk | GlusterFS | With Collabora |
| nginx-sites | brmartin.co.uk, martinilink.co.uk | GlusterFS | Static sites |
| ollama | N/A (internal) | GlusterFS | GPU workload |
| open-webui | chat.brmartin.co.uk | Litestream | SQLite database |
| overseerr | overseerr.brmartin.co.uk | Litestream | SQLite database (delete K8s PoC first) |
| renovate | N/A (periodic) | None | CronJob |
| restic-backup | N/A (periodic) | GlusterFS access | CronJob |
| searxng | searx.brmartin.co.uk | None | OAuth protected |
| vaultwarden | bw.brmartin.co.uk | Litestream | Critical passwords |

### Services NOT to Migrate

| Service | Reason |
|---------|--------|
| media-centre | Peak-time, explicitly excluded |
| plugin-glusterfs-* | CSI infrastructure |
| plugin-martinibar-* | CSI infrastructure |
| traefik | External Docker container |
| plextraktsync | Part of media-centre ecosystem |

### Key Entities

- **K8s Deployment/StatefulSet**: Workload running a service (replaces Nomad job)
- **K8s Service**: Internal service discovery (replaces Consul service)
- **K8s Ingress**: External routing (works with K8s Traefik)
- **PersistentVolumeClaim**: Storage binding (uses democratic-csi for GlusterFS)
- **ExternalSecret**: Vault secret synchronization
- **CiliumNetworkPolicy**: Service mesh access control (replaces Consul intentions)
- **CronJob**: Scheduled tasks (replaces Nomad periodic jobs)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 15+ services accessible at original URLs within 5 seconds response time
- **SC-002**: Zero data loss verified by spot-checking key artifacts in each service
- **SC-003**: All migrated services pass health checks continuously for 24 hours post-migration
- **SC-004**: Nomad job count reduced from ~20 to ~5 (media-centre ecosystem + CSI plugins)
- **SC-005**: Service mesh encryption visible in Hubble for inter-service communication
- **SC-006**: Cluster memory usage remains stable (K8s overhead offset by Nomad job reduction)
- **SC-007**: All periodic jobs (renovate, restic-backup) execute successfully on schedule

## Assumptions

1. GlusterFS CSI (democratic-csi) works identically in K8s as it does in Nomad
2. External Traefik can route to K8s Traefik without additional configuration beyond what exists
3. Wildcard TLS certificate can be copied to all required K8s namespaces
4. MinIO remains accessible to K8s pods via Consul DNS or direct service discovery
5. OAuth2-proxy middleware works with K8s-routed services (verified in PoC)
6. Services don't require Nomad-specific features (Consul intentions can be replicated with CiliumNetworkPolicy)

## Constraints

1. Media-centre MUST NOT be migrated during this phase
2. CSI plugins MUST remain on Nomad (they provide storage to both orchestrators)
3. External Traefik MUST remain on Docker (it's the public entry point)

## Migration Strategy

### One Service at a Time

Due to limited cluster resources, services MUST be migrated sequentially:

1. **Stop Nomad job first** - Prevents storage conflicts and frees resources
2. **Deploy K8s workload** - Create the K8s equivalent
3. **Verify service works** - Test URL access, data integrity, functionality
4. **Proceed to next service** - Only after current service is confirmed working

**Rationale**: The cluster has low available resources. Running duplicate services (Nomad + K8s) for heavy workloads can cause OOM kills and cascade failures.

### Downtime Acceptance

- Downtime for all services (except media-centre) is **acceptable**
- Each service will be unavailable during its migration window
- Expected downtime per service: 5-15 minutes (depending on complexity)

### Suggested Migration Order

Start with simpler, lower-risk services to build confidence:

| Phase | Services | Rationale |
|-------|----------|-----------|
| 1 | searxng, nginx-sites | Stateless/simple, low risk |
| 2 | vaultwarden, overseerr | Litestream pattern (proven in PoC) |
| 3 | open-webui, ollama | AI stack, GPU workload |
| 4 | minio | Critical infrastructure - needed by litestream services |
| 5 | keycloak | SSO provider - other services depend on it |
| 6 | appflowy | Multi-container but self-contained |
| 7 | elk | Observability - useful for debugging later migrations |
| 8 | nextcloud | Complex but well-understood |
| 9 | matrix | Complex multi-component |
| 10 | gitlab, gitlab-runner | Most complex - save for last |
| 11 | renovate, restic-backup | Periodic jobs (CronJobs) |

### Rollback Plan

If a K8s service fails after migration:
1. Delete the K8s workload
2. Re-run the Nomad job
3. Investigate and fix before retrying

## Dependencies

- K8s cluster already running (from 003-nomad-to-kubernetes PoC)
- Cilium CNI with Hubble installed
- External Secrets Operator configured with Vault
- Traefik Ingress Controller running in K8s
- TLS wildcard certificate available
