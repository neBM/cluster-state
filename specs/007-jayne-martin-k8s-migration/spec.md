# Feature Specification: Jayne Martin Counselling K8s Migration and Nomad Removal

**Feature Branch**: `007-jayne-martin-k8s-migration`  
**Created**: 2026-01-24  
**Status**: Draft  
**Input**: User description: "There exists one more service in nomad that has yet to be migrated to k8s: Jayne martin counselling website. Migrate this to k8s. Once this is done, analysis can be done to determine if nomad and is unused on all nodes. If so, uninstall nomad and on all nodes. Consul and vault will remain for now."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Website Availability on Kubernetes (Priority: P1)

As the Jayne Martin Counselling website administrator, I need the website to be accessible at www.jaynemartincounselling.co.uk so that clients can view services and contact information without interruption during or after migration.

**Why this priority**: Core business continuity - the website must remain accessible throughout and after migration to avoid any client-facing downtime.

**Independent Test**: Can be fully tested by accessing www.jaynemartincounselling.co.uk after K8s deployment and verifying page content loads correctly, delivering a functional public website.

**Acceptance Scenarios**:

1. **Given** the K8s deployment is running, **When** a user visits www.jaynemartincounselling.co.uk, **Then** the website loads successfully with all content visible
2. **Given** the K8s deployment is running, **When** the health check endpoint is probed, **Then** a successful response is returned within 5 seconds
3. **Given** both Nomad and K8s deployments are running (during cutover), **When** Traefik routes traffic to K8s, **Then** the website continues to serve identical content

---

### User Story 2 - Nomad Service Decommissioning (Priority: P2)

As a cluster administrator, I need to safely decommission the Nomad job for Jayne Martin Counselling after verifying K8s serves the site correctly, so that Nomad no longer manages any production workloads.

**Why this priority**: This clears the path for Nomad removal but depends on successful K8s migration validation.

**Independent Test**: Can be fully tested by stopping the Nomad job and verifying the website still functions via K8s, delivering confirmation that Nomad is no longer required for this service.

**Acceptance Scenarios**:

1. **Given** the K8s deployment is verified working, **When** the Nomad job is stopped, **Then** the website remains accessible via K8s
2. **Given** the Nomad job is stopped, **When** Terraform state is updated, **Then** the Nomad module is removed from main.tf without errors

---

### User Story 3 - Nomad Cluster Analysis and Removal (Priority: P3)

As a cluster administrator, I need to analyze whether Nomad is completely unused across all cluster nodes and remove it if confirmed, so that I can simplify cluster operations and reduce maintenance overhead while retaining Consul and Vault.

**Why this priority**: Optional cleanup that provides operational benefits but is not critical for service functionality. Depends on successful completion of P1 and P2.

**Independent Test**: Can be fully tested by verifying no Nomad jobs exist, no Nomad agents are serving traffic, and then uninstalling Nomad from each node, delivering a simplified infrastructure stack.

**Acceptance Scenarios**:

1. **Given** no services remain on Nomad, **When** running `nomad job status`, **Then** no running jobs are listed (excluding system jobs if any)
2. **Given** Nomad is confirmed unused, **When** Nomad agent is stopped and uninstalled on each node, **Then** all other services (K8s, Consul, Vault) continue operating normally
3. **Given** Nomad is removed, **When** the cluster state documentation is updated, **Then** AGENTS.md and related docs reflect Nomad removal

---

### Edge Cases

- What happens if the container image is unavailable from the registry during deployment?
- How does the system handle if external Traefik cannot route to the new K8s service initially?
- What happens if the external Traefik configuration update fails mid-cutover?
- What happens if Nomad removal breaks any unexpected dependencies (e.g., Consul Connect sidecar configurations)?
- How does the system recover if K8s deployment fails after Nomad job is stopped?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST deploy the Jayne Martin Counselling website container to Kubernetes as a Deployment resource
- **FR-002**: System MUST expose the website via a ClusterIP Service on port 80
- **FR-003**: System MUST configure K8s Ingress resource for hostname www.jaynemartincounselling.co.uk with HTTPS/TLS
- **FR-010**: System MUST update the external Traefik configuration on Hestia to route www.jaynemartincounselling.co.uk traffic to the K8s service (replacing the Nomad/Consul Connect route)
- **FR-004**: System MUST include health check probes (liveness and readiness) for the deployment
- **FR-005**: System MUST use the existing container image `registry.brmartin.co.uk/jayne-martin-counselling/website:latest`
- **FR-006**: System MUST remove the Nomad module definition from main.tf after K8s migration is validated
- **FR-007**: System MUST document the Nomad removal process and verify no remaining Nomad-managed services exist
- **FR-008**: System MUST update AGENTS.md to reflect that Nomad is no longer in use (if fully removed)
- **FR-009**: System MUST support multi-arch deployment (amd64/arm64) to allow scheduling on any cluster node

### Key Entities

- **K8s Deployment**: Manages the jayne-martin-counselling container lifecycle with replica management
- **K8s Service**: Exposes the deployment internally within the cluster on port 80
- **K8s Ingress**: Defines the routing rule for www.jaynemartincounselling.co.uk within K8s
- **External Traefik Config**: Configuration on Hestia that routes external traffic to K8s services
- **Terraform Module**: New module at modules-k8s/jayne-martin-counselling/ defining all K8s resources

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Website is accessible at www.jaynemartincounselling.co.uk within 30 seconds of K8s deployment completion
- **SC-002**: Zero downtime during migration - website remains accessible throughout cutover process
- **SC-003**: Health checks pass consistently (100% over 5-minute observation period) after K8s deployment
- **SC-004**: Nomad job count reaches zero after decommissioning (excluding any system-level jobs)
- **SC-005**: If Nomad is fully removed, Nomad agent processes are not running on any of the 3 cluster nodes
- **SC-006**: Consul and Vault services continue operating normally after any Nomad changes

## Assumptions

- The existing TLS certificate for jaynemartincounselling.co.uk is available as a Kubernetes secret (wildcard-brmartin-tls or similar)
- The container image registry.brmartin.co.uk is accessible from all K8s nodes
- External Traefik on Hestia handles incoming HTTPS traffic and will need configuration updates to route to K8s instead of Nomad/Consul
- The website is stateless and requires no persistent storage
- DNS for www.jaynemartincounselling.co.uk already points to the cluster ingress
- Nomad removal will be performed manually on each node (systemd service stop + package removal), not via automated tooling
