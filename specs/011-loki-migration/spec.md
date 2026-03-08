# Feature Specification: ELK to Loki Migration

**Feature Branch**: `011-loki-migration`  
**Created**: 2026-03-08  
**Status**: Draft  
**Input**: User description: "Migrate from ELK stack (Elasticsearch, Kibana, Elastic Agent) to Grafana Loki + Grafana Alloy to dramatically reduce cluster RAM usage. APM is non-critical. Enrichment pipelines are non-critical."

## Context

The cluster currently runs a 3-node Elasticsearch cluster (2 data nodes + 1 tiebreaker), Kibana, and an Elastic Agent DaemonSet consuming approximately 11–12 GB of RAM cluster-wide. One data node (Heracles) runs at 100% RAM capacity. The goal is to replace this stack with Grafana Loki backed by the existing MinIO object store, and Grafana Alloy as the log collection agent. Grafana is already deployed in the cluster and will serve as the UI replacement for Kibana.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Browse and Search Logs in Grafana Explore (Priority: P1)

An operator needs to investigate a problem with a service (e.g., GitLab, Matrix, Plex) and wants to browse recent logs and search for specific error messages or patterns.

**Why this priority**: This is the primary day-to-day use case for the logging stack. Everything else is secondary to being able to find and read logs.

**Independent Test**: Can be fully tested by opening Grafana Explore, selecting the Loki data source, querying for a specific service's logs, and verifying log lines appear with the correct content and timestamps.

**Acceptance Scenarios**:

1. **Given** the operator opens Grafana Explore and selects the Loki data source, **When** they filter by `namespace=default` and `container=gitlab-webservice`, **Then** they see recent log lines from that container within a few seconds.
2. **Given** the operator enters a text search (e.g., `|= "error"`), **When** they submit the query, **Then** matching log lines are returned and highlighted within the visible time range.
3. **Given** the operator selects a time range (e.g., "last 6 hours"), **When** they execute a query, **Then** results are scoped to that time range.

---

### User Story 2 - All Kubernetes Container Logs Collected (Priority: P1)

All pod logs from the cluster are captured and available in Loki with appropriate labels for filtering by namespace, pod, container, and node.

**Why this priority**: Without complete log coverage, the migration cannot replace the existing stack. This is a prerequisite for decommissioning Elastic Agent.

**Independent Test**: Can be tested by listing all running pods, querying Loki for each pod's namespace and container label, and verifying log lines are present.

**Acceptance Scenarios**:

1. **Given** a pod is running in the `default` namespace, **When** it emits log lines to stdout/stderr, **Then** those lines appear in Loki within 60 seconds with correct `namespace`, `pod`, and `container` labels.
2. **Given** a pod is running on any of the three nodes (Hestia, Heracles, Nyx), **When** queried by node label, **Then** its logs are accessible regardless of which node it runs on.
3. **Given** a pod is restarted, **When** the new instance emits logs, **Then** logs from both the previous and current instance are available (differentiated by timestamp).

---

### User Story 3 - System and Host Logs Collected (Priority: P2)

Syslog, auth logs, and host-level journal entries from all three nodes are captured and queryable.

**Why this priority**: These are currently collected by Elastic Agent and are useful for diagnosing host-level issues (SSH logins, systemd failures, kernel messages). Secondary to container logs.

**Independent Test**: Can be tested by SSHing to a node, generating a syslog entry, and verifying it appears in Loki under the appropriate label.

**Acceptance Scenarios**:

1. **Given** a systemd service starts or stops on any node, **When** queried by host and log type, **Then** the relevant journal entry appears in Loki.
2. **Given** an SSH login occurs, **When** queried for auth logs from that node, **Then** the login event is visible in Loki.

---

### User Story 4 - Traefik Access Logs Collected (Priority: P2)

Traefik access logs (the single largest data source at ~21 GB uncompressed) are collected and queryable, replacing the current Elasticsearch index.

**Why this priority**: Currently the biggest storage consumer. Capturing these in Loki is important for completeness but not as critical as general container/service logs for day-to-day operations.

**Independent Test**: Can be tested by making an HTTP request through Traefik and verifying the access log entry appears in Loki.

**Acceptance Scenarios**:

1. **Given** an HTTP request is routed through Traefik, **When** queried by the Traefik job label, **Then** the access log line appears in Loki with request method, path, and status code visible.

---

### User Story 5 - Cluster RAM Freed After Decommission (Priority: P1)

Once Loki is validated as the log backend, Elasticsearch, Kibana, Elastic Agent DaemonSet, and Fleet Server are removed from the cluster, freeing approximately 11 GB of RAM.

**Why this priority**: This is the primary motivation for the migration. Without decommissioning the old stack, no RAM is saved.

**Independent Test**: Can be tested by checking node memory usage before and after decommission and confirming Heracles is no longer at 100% RAM.

**Acceptance Scenarios**:

1. **Given** Loki is validated and serving logs, **When** the ELK stack is decommissioned, **Then** node memory usage shows Heracles below 75% (from current 100%).
2. **Given** the ELK stack is removed, **When** the cluster is inspected, **Then** no Elasticsearch, Kibana, or Elastic Agent pods exist.
3. **Given** the ELK stack is removed, **When** the cluster is inspected, **Then** the 100 GB of local NVMe storage previously used by Elasticsearch data nodes is reclaimed.

---

### User Story 6 - Log Retention Configured (Priority: P2)

Logs are retained for 30 days (matching the current ILM policy) and automatically deleted thereafter.

**Why this priority**: Without retention, storage grows unbounded. The existing 30-day policy is the baseline requirement.

**Independent Test**: Can be tested by verifying the Loki retention configuration and observing old log chunks being deleted from MinIO after the retention period.

**Acceptance Scenarios**:

1. **Given** Loki retention is configured for 30 days, **When** a log chunk is older than 30 days, **Then** it is automatically deleted from MinIO storage.
2. **Given** retention is active, **When** querying for logs older than 30 days, **Then** no results are returned.

---

### Edge Cases

- What happens when MinIO is temporarily unavailable? Alloy should buffer logs locally and retry without dropping them.
- What happens when a node is rebooted? The Alloy DaemonSet pod restarts and resumes collection without duplicating or losing previously shipped logs.
- What happens during the parallel running period (both Elastic Agent and Alloy collecting)? Both collect logs simultaneously — duplication in each respective backend is acceptable during validation.
- What if the Loki pod crashes or restarts? Alloy buffers unsent logs and replays them once Loki recovers.
- How are label cardinality explosions avoided? Labels must be limited to low-cardinality values (namespace, pod, container, node, job) — log content must not be used as a label.
- What happens to the existing Elasticsearch data (historical logs) when ES is decommissioned? Historical data is not migrated — it is deleted along with the ES PVCs. Only logs from the Alloy deployment date onward are available in Loki.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST collect stdout/stderr logs from all Kubernetes pods across all three cluster nodes.
- **FR-002**: Collected logs MUST carry at minimum these labels: `namespace`, `pod`, `container`, `node`, and `job`.
- **FR-003**: The system MUST store collected logs in the existing MinIO deployment as the object storage backend.
- **FR-004**: Logs MUST be automatically deleted after 30 days with no manual intervention required.
- **FR-005**: The system MUST expose a query API compatible with the existing Grafana instance's Loki data source plugin.
- **FR-006**: Grafana MUST have a Loki data source configured so operators can query and browse logs via Grafana Explore without installing or accessing any additional tool.
- **FR-007**: The system MUST collect host-level logs (syslog, auth, journal) from all three nodes.
- **FR-008**: The system MUST collect Traefik access logs.
- **FR-009**: Health check and liveness probe log noise MUST be filtered out before storage (equivalent to the current kube-probe drop rule).
- **FR-010**: The log collection agent MUST run on all three nodes including the control-plane node.
- **FR-011**: After full migration, the system MUST NOT include any Elasticsearch, Kibana, Elastic Agent, or Fleet Server components.
- **FR-012**: The existing Grafana deployment MUST be the sole log browsing interface — no new UI components are to be introduced.
- **FR-013**: The system MUST NOT require any changes to application or service configuration (collection is purely infrastructure-level).

### Key Entities

- **Log Stream**: A set of log lines sharing identical label values (e.g., all lines from `container=gitlab-webservice` in `namespace=default`). The fundamental unit of storage in Loki.
- **Label Set**: The metadata key-value pairs attached to each log stream. Used for filtering and routing. Must be kept low-cardinality (namespace, pod, container, node, job — not log content).
- **Chunk**: A compressed block of log lines for a single stream, written to MinIO as an object. The storage unit.
- **Retention Policy**: A time-based rule that automatically deletes log chunks older than 30 days via the Loki compactor process.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Cluster total RAM consumption decreases by at least 9 GB after decommissioning the ELK stack (from ~11 GB consumed by ELK to under 2 GB for Loki + Alloy).
- **SC-002**: Heracles node RAM usage drops below 75% after decommissioning (from current 100%).
- **SC-003**: Logs from all running pods are visible in Grafana Explore within 60 seconds of being emitted.
- **SC-004**: A log search by container name and text pattern returns results in under 10 seconds for a 1-hour time window.
- **SC-005**: Log storage in MinIO for 30 days of data occupies less than 10 GB (vs. the current ~35 GB in Elasticsearch).
- **SC-006**: No log gaps (missing coverage windows) exist for any running service during the cutover period.
- **SC-007**: The ELK stack (Elasticsearch, Kibana, Elastic Agent, Fleet Server) is fully removed with no remaining pods, PersistentVolumeClaims, DaemonSets, or associated Kubernetes resources.
- **SC-008**: Zero application or service configuration changes are required to achieve full log collection coverage.

## Assumptions

- MinIO is healthy and has sufficient free capacity for compressed log storage (~3–5 GB/month estimated, well within MinIO's available space).
- Grafana is deployed and accessible at `https://grafana.brmartin.co.uk`. A Loki data source will be added to the existing instance without replacing it.
- APM data (traces from `cooking_planner`, `kitchen_tempo`) is non-critical and will be dropped with no replacement.
- The Elasticsearch ingest enrichment pipelines (GeoIP, error categorisation, GitLab/Matrix field extraction) are not required. Basic label-based filtering is sufficient for the operator's needs.
- Loki will be deployed in single-pod monolithic mode, which is appropriate for the cluster's log volume.
- Historical Elasticsearch log data (pre-migration) will not be migrated to Loki and will be deleted when ES PVCs are removed. This is acceptable.
- The parallel running period (Alloy + Elastic Agent both active) will last until the operator confirms Loki coverage is satisfactory, then ELK is decommissioned.
- Loki's write-ahead log (WAL) will be stored on ephemeral local storage (not network-attached storage), given the cluster's known SQLite-on-NFS limitations.

## Out of Scope

- APM / distributed tracing — dropped without replacement.
- Replication of the 92-processor Elasticsearch ingest enrichment pipeline (GeoIP, error categorisation, GitLab/Matrix/Synapse field extraction).
- Kibana dashboard migration — Kibana is decommissioned entirely; no dashboards are recreated.
- Audit log (`auditd`) collection — can be added post-migration if needed.
- Alerting rules based on log content — can be configured in Grafana/Loki post-migration.
- Migration of historical Elasticsearch log data to Loki.
- Multi-tenancy in Loki — single-tenant mode is sufficient.
