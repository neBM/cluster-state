# Feature Specification: GitLab Multi-Container Migration

**Feature Branch**: `008-gitlab-multi-container`  
**Created**: 2026-01-24  
**Status**: Draft  
**Input**: User description: "Gitlab is currently using a single container to host all its components. This violates the single responsibility principle. Migrate away from using a single container. You may explore gitlab documentation to see additional details. Service config should be similar/the same. Downtime is acceptable. Pre-existing projects/access tokens/etc must still be available with no changes. Prefer to avoid using Helm charts."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Data Preservation During Migration (Priority: P1)

As a GitLab administrator, I want to migrate to a multi-container architecture while preserving all existing data, so that users experience no loss of their projects, repositories, access tokens, or configurations.

**Why this priority**: Without data preservation, the migration would be catastrophic for users. All git repositories, CI/CD configurations, access tokens, user accounts, and project settings must remain intact after migration. This is the core requirement that makes any architectural change acceptable.

**Independent Test**: Can be fully tested by accessing GitLab after migration and verifying that all existing repositories can be cloned, pushed to, and that all user accounts and access tokens function as before.

**Acceptance Scenarios**:

1. **Given** an existing GitLab instance with repositories, users, and access tokens, **When** the migration to multi-container architecture is complete, **Then** all repositories should be accessible with full git history intact.
2. **Given** users with personal access tokens configured for API/CI access, **When** the migration completes, **Then** existing access tokens must continue to authenticate successfully without regeneration.
3. **Given** projects with CI/CD pipelines configured, **When** the migration completes, **Then** all pipeline configurations and secrets remain functional.
4. **Given** container registry images pushed to the GitLab registry, **When** the migration completes, **Then** all images should be pullable with existing authentication.

---

### User Story 2 - Core GitLab Functionality (Priority: P1)

As a GitLab user, I want all core GitLab features to work after migration, so that I can continue my development workflows without interruption.

**Why this priority**: Users must be able to perform their daily development activities. Without functional core features, GitLab is unusable regardless of architectural improvements.

**Independent Test**: Can be fully tested by performing common GitLab operations: browsing repositories, pushing/pulling via HTTPS, viewing merge requests, and running CI pipelines.

**Acceptance Scenarios**:

1. **Given** a migrated GitLab instance, **When** a user accesses the web UI, **Then** the GitLab dashboard loads and all navigation functions correctly.
2. **Given** a migrated GitLab instance, **When** a user pushes code via Git over HTTPS, **Then** the push completes successfully with proper authentication.
3. **Given** a CI pipeline trigger event, **When** the pipeline is executed, **Then** Sidekiq processes the jobs and runners receive work.
4. **Given** a user accessing the container registry, **When** they push or pull an image, **Then** the operation completes successfully.

---

### User Story 3 - Service Isolation and Single Responsibility (Priority: P2)

As a system administrator, I want GitLab components separated into individual containers following the single responsibility principle, so that I can manage, scale, and troubleshoot components independently.

**Why this priority**: This is the primary goal of the migration, enabling better operational control. However, it only matters if the system functions correctly first (P1 stories).

**Independent Test**: Can be fully tested by verifying that each GitLab component runs in its own container and can be restarted/scaled independently without affecting other components unnecessarily.

**Acceptance Scenarios**:

1. **Given** the migrated architecture, **When** I inspect running containers, **Then** I see separate containers for webservice, sidekiq, gitaly, and workhorse components.
2. **Given** a running GitLab deployment, **When** I restart the Sidekiq container, **Then** the web UI remains accessible and git operations continue (though background jobs may queue).
3. **Given** a running GitLab deployment, **When** I restart the webservice container, **Then** other components remain running (graceful degradation).
4. **Given** the need to view logs for a specific component, **When** I access container logs, **Then** I see only logs relevant to that specific service.

---

### User Story 4 - External Service Integration (Priority: P2)

As a system administrator, I want the multi-container deployment to continue using existing external services (PostgreSQL, Redis), so that I can maintain my current database and caching infrastructure.

**Why this priority**: The existing infrastructure uses an external PostgreSQL server and has Redis configuration that works. Changing these would increase migration risk and complexity.

**Independent Test**: Can be fully tested by verifying database connections point to the external PostgreSQL server and Redis operations function correctly.

**Acceptance Scenarios**:

1. **Given** the existing external PostgreSQL database at 192.168.1.10:5433, **When** the migrated GitLab connects, **Then** all database operations use this external server.
2. **Given** the migration architecture, **When** Redis is required, **Then** a dedicated Redis container is deployed (or existing external Redis is used) and all components connect successfully.
3. **Given** the migrated deployment, **When** I check database connections, **Then** no embedded PostgreSQL is running within any GitLab container.

---

### User Story 5 - Migration Execution (Priority: P3)

As a system administrator, I want a clear migration procedure that accepts downtime, so that I can execute the migration with confidence during a maintenance window.

**Why this priority**: While downtime is acceptable, the migration procedure should be clear to minimize downtime duration and reduce risk of errors.

**Independent Test**: Can be fully tested by documenting and executing the migration steps in a test environment.

**Acceptance Scenarios**:

1. **Given** the current omnibus GitLab deployment, **When** I begin migration, **Then** I can gracefully stop the current deployment.
2. **Given** stopped services and existing data volumes, **When** I deploy the new multi-container architecture, **Then** containers start successfully and access existing data.
3. **Given** completed migration, **When** I verify the deployment, **Then** I have a checklist to confirm all components are functioning.

---

### Edge Cases

- What happens if a component container crashes during normal operation? (Other components should continue functioning where possible; Kubernetes handles restart)
- How does the system handle if Gitaly is unavailable? (Git operations fail gracefully, web UI shows appropriate errors, users can still access non-git features)
- What happens if the shared storage becomes temporarily unavailable? (All components requiring storage should fail gracefully and recover when storage returns)
- How are secrets shared between containers? (Secrets must be properly mounted to each container that requires them)
- What happens to in-flight requests during container restarts? (Requests may fail; clients should retry; this is acceptable with downtime being permitted)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST deploy GitLab components as separate containers: webservice (Puma), workhorse, sidekiq, and gitaly
- **FR-002**: System MUST preserve all existing Git repositories with full history during migration
- **FR-003**: System MUST preserve all user accounts, access tokens, and authentication configurations
- **FR-004**: System MUST preserve all project settings, CI/CD configurations, and secrets
- **FR-005**: System MUST continue using the external PostgreSQL database (192.168.1.10:5433)
- **FR-006**: System MUST provide Redis connectivity for all components that require it
- **FR-007**: System MUST support Git operations over HTTPS via the existing ingress (git.brmartin.co.uk)
- **FR-008**: System MUST support container registry operations via the existing ingress (registry.brmartin.co.uk)
- **FR-009**: System MUST handle inter-component communication (workhorse to webservice, webservice to gitaly, etc.)
- **FR-010**: System MUST store persistent data using PersistentVolumeClaims with the glusterfs-nfs StorageClass (automatic directory provisioning)
- **FR-011**: System MUST NOT use Helm charts for deployment (use Terraform with Kubernetes provider instead)
- **FR-012**: System MUST use Cloud Native GitLab (CNG) container images from registry.gitlab.com/gitlab-org/build/cng
- **FR-013**: System MUST share necessary secrets between components (database password, workhorse secret, gitaly token, etc.)
- **FR-014**: System MAY run on any cluster node (GlusterFS NFS storage is accessible from all nodes)
- **FR-015**: System SHOULD support Git operations over SSH (nice-to-have, not currently working)

### Key Entities

- **GitLab Webservice**: The Puma-based Rails application serving the web UI and API
- **GitLab Workhorse**: Smart reverse proxy handling large file uploads, git operations, and websockets
- **GitLab Sidekiq**: Background job processor for async tasks (emails, webhooks, CI pipelines)
- **Gitaly**: Git storage service providing RPC access to git repositories
- **GitLab Shell**: SSH server component for Git over SSH operations (optional, nice-to-have)
- **Redis**: In-memory cache and message queue for inter-component communication
- **Container Registry**: Docker registry for storing container images (may remain bundled or separate)
- **Shared Volumes**: PVC-provisioned storage for repositories, uploads, and shared state (backed by GlusterFS NFS)
- **Secrets**: Shared authentication tokens between components (workhorse secret, gitaly token)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All existing Git repositories (100%) can be cloned and pushed to after migration
- **SC-002**: All existing user access tokens continue to function without modification
- **SC-003**: GitLab web UI loads successfully and all navigation works within normal response times
- **SC-004**: Git push/pull operations complete successfully via HTTPS
- **SC-005**: CI/CD pipelines trigger and execute successfully using existing runner configuration
- **SC-006**: Container registry push/pull operations complete successfully
- **SC-007**: Each GitLab component runs in its own separate container (minimum 4 containers: webservice, workhorse, sidekiq, gitaly)
- **SC-008**: Individual component containers can be restarted without causing complete service outage (graceful degradation)
- **SC-009**: Migration can be completed within a single maintenance window (target: under 2 hours downtime)
- **SC-010**: No data loss of any kind: repositories, user data, CI configurations, or registry images

## Assumptions

- The CNG (Cloud Native GitLab) container images at registry.gitlab.com/gitlab-org/build/cng are suitable for non-Helm deployments and can be configured via environment variables and mounted configuration files
- CNG components use TCP for all inter-component communication (no Unix sockets required), eliminating GlusterFS socket compatibility concerns
- PVCs with the glusterfs-nfs StorageClass can be used for all persistent storage (no hostPath mounts needed)
- The external PostgreSQL database schema is compatible with the CNG images (same GitLab version or compatible migration path)
- The current GitLab version (18.8.2-ce.0) has corresponding CNG images available
- Redis can be deployed as a separate container in the same namespace with TCP connectivity to all components
- Terraform's kubernetes provider can manage all required resources without needing Helm
- The existing Traefik ingress configuration can route to the new services without modification (only service names may change)
- All necessary secrets (workhorse secret, gitaly token, registry key) can be generated or extracted from the existing omnibus configuration
- Existing data from the omnibus deployment can be migrated to PVC-backed storage during the maintenance window

## Out of Scope

- High availability or horizontal scaling of components (single replica per component is acceptable)
- Upgrading GitLab version as part of this migration
- Changing the external PostgreSQL database configuration
- Modifying the GlusterFS storage architecture
- Adding new GitLab features or capabilities not present in current deployment
- Performance optimization beyond matching current performance levels
- Migrating GitLab Runners (they already run separately)
- Setting up GitLab Pages (not currently enabled)
- Setting up GitLab KAS/Agent for Kubernetes (not currently enabled)
