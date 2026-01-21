# Feature Specification: Migrate Overseerr to Nomad

**Feature Branch**: `001-migrate-overseerr-nomad`  
**Created**: 2026-01-20  
**Status**: Draft  
**Input**: User description: "Migrate Overseerr media request management service from docker-compose to Nomad"

## Clarifications

### Session 2026-01-20

- Q: How should Overseerr connect to Sonarr/Radarr given they remain on docker-compose? → A: Direct IP connections to Hestia (192.168.1.5)
- Q: Should Overseerr be constrained to Hestia node? → A: No constraint - allow flexible scheduling for failover
- Q: Should Overseerr use litestream for SQLite backup? → A: Yes - confirmed SQLite in use (db.sqlite3 with WAL), use litestream pattern for production reliability and consistency with Plex

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Access Overseerr Web UI (Priority: P1)

As a media library user, I want to access the Overseerr web interface via a secure URL so I can request movies and TV shows to be added to the media library.

**Why this priority**: Core functionality - without web UI access, users cannot make any media requests. This is the fundamental purpose of the service.

**Independent Test**: Can be fully tested by navigating to `overseerr.brmartin.co.uk` in a browser and verifying the login page loads with valid HTTPS certificate.

**Acceptance Scenarios**:

1. **Given** the Overseerr service is deployed on Nomad, **When** a user navigates to `https://overseerr.brmartin.co.uk`, **Then** the Overseerr login/home page loads successfully over HTTPS
2. **Given** the Overseerr service is deployed on Nomad, **When** a user authenticates with their Plex account, **Then** they are logged into Overseerr and can view the request interface
3. **Given** the Overseerr service has been restarted, **When** a user accesses the web UI, **Then** their previous authentication session and preferences are preserved

---

### User Story 2 - Configuration Persistence (Priority: P1)

As a system administrator, I want Overseerr's configuration and database to persist across restarts and redeployments so that user accounts, request history, and integrations remain intact.

**Why this priority**: Critical for service continuity - losing configuration would require full reconfiguration of all integrations and loss of request history.

**Independent Test**: Can be verified by stopping the Nomad job, restarting it, and confirming all settings, users, and request history are preserved.

**Acceptance Scenarios**:

1. **Given** Overseerr has been configured with Plex/Sonarr/Radarr integrations, **When** the Nomad job is stopped and restarted, **Then** all integration settings are preserved
2. **Given** users have made media requests, **When** the service is redeployed, **Then** all historical requests and their statuses are retained
3. **Given** the underlying node is rebooted, **When** the service comes back online, **Then** the database is restored from MinIO backup and all data is intact
4. **Given** the Overseerr allocation moves to a different node, **When** it starts on the new node, **Then** litestream restores the database from MinIO before the service starts

---

### User Story 3 - Media Service Integration (Priority: P1)

As a media library user, I want Overseerr to communicate with Plex, Sonarr, and Radarr so that my requests are automatically fulfilled by the download automation.

**Why this priority**: Without these integrations, Overseerr cannot fulfill its core purpose of automated media requesting.

**Independent Test**: Can be tested by making a movie request and verifying it appears in Radarr, or a TV request appearing in Sonarr.

**Acceptance Scenarios**:

1. **Given** Overseerr is configured with Radarr, **When** a user requests a movie, **Then** the request is sent to Radarr's API and appears in Radarr's queue
2. **Given** Overseerr is configured with Sonarr, **When** a user requests a TV series, **Then** the request is sent to Sonarr's API and appears in Sonarr's queue
3. **Given** Overseerr is configured with Plex, **When** new media is added to Plex, **Then** Overseerr can detect the media and update request statuses accordingly

---

### User Story 4 - Flexible Node Scheduling (Priority: P2)

As a system administrator, I want Overseerr to be schedulable on any cluster node so that Nomad can reschedule the service during node failures, enabling high availability.

**Why this priority**: Enables failover capability - if the current node goes down, Nomad can automatically reschedule Overseerr to a healthy node.

**Independent Test**: Can be verified by draining the node running Overseerr and confirming it reschedules to another node while maintaining connectivity to backend services.

**Acceptance Scenarios**:

1. **Given** the Nomad job is deployed without node constraints, **When** the current node becomes unavailable, **Then** Nomad reschedules Overseerr to another healthy node
2. **Given** Overseerr is running on any cluster node, **When** it connects to Sonarr/Radarr, **Then** it successfully reaches them via Hestia's IP address (192.168.1.5)

---

### User Story 5 - Database Backup and Recovery (Priority: P1)

As a system administrator, I want Overseerr's SQLite database to be continuously backed up to object storage so that data can be recovered in case of node failure or corruption.

**Why this priority**: Production data protection - prevents data loss and enables reliable failover across nodes.

**Independent Test**: Can be verified by checking MinIO bucket for recent litestream snapshots and WAL segments after making a request in Overseerr.

**Acceptance Scenarios**:

1. **Given** Overseerr is running with litestream sidecar, **When** a user submits a media request, **Then** the database change is replicated to MinIO within 5 minutes
2. **Given** the Overseerr allocation is stopped, **When** a new allocation starts (on any node), **Then** litestream restore task retrieves the latest database from MinIO before Overseerr starts
3. **Given** MinIO contains a valid backup, **When** restoring to a fresh allocation, **Then** all historical data (users, requests, settings) is recovered

---

### User Story 6 - Data Migration from Docker Compose (Priority: P1)

As a system administrator, I want to migrate all existing Overseerr data from the docker-compose deployment to the new Nomad deployment so that users retain their accounts, request history, and all configured integrations.

**Why this priority**: Critical for production migration - without data migration, all user accounts, request history, and integration configurations would be lost, requiring complete reconfiguration and losing historical data.

**Independent Test**: Can be verified by comparing user counts, request counts, and integration settings between the old docker-compose instance and the new Nomad deployment.

**Acceptance Scenarios**:

1. **Given** the existing docker-compose Overseerr has production data, **When** migration is performed, **Then** all user accounts are preserved and users can log in with existing Plex credentials
2. **Given** the existing database contains media request history, **When** migration is performed, **Then** all historical requests (pending, approved, available) are visible in the new deployment
3. **Given** the existing settings.json contains Plex/Sonarr/Radarr integration configs, **When** migration is performed, **Then** all integrations work without reconfiguration (API keys, URLs preserved)
4. **Given** the docker-compose Overseerr is stopped for migration, **When** the Nomad deployment starts, **Then** downtime is less than 10 minutes
5. **Given** the migration has completed, **When** verifying data integrity, **Then** the database record count matches the original (users, requests, media items)

**Migration Sequence**:

1. **Pre-migration backup**: Create backup of docker-compose data (`/var/lib/docker/volumes/downloads_config-overseerr/_data/`)
2. **Stop docker-compose**: `docker stop overseerr` on Hestia
3. **Seed litestream**: Run one-time litestream replicate to upload database to MinIO
4. **Create GlusterFS volume**: Apply Terraform to create CSI volume
5. **Copy settings.json**: Copy configuration file to GlusterFS volume
6. **Deploy Nomad job**: Apply Terraform to start Overseerr on Nomad
7. **Verify migration**: Check user accounts, request history, integrations
8. **Cleanup**: Remove docker-compose container after verification period

**Rollback Plan**:

- Keep docker-compose definition and data intact until Nomad deployment is verified (minimum 24 hours)
- If issues occur: `nomad job stop overseerr` and `docker start overseerr` on Hestia

---

### Edge Cases

- What happens when MinIO is unavailable during startup?
  - Litestream restore waits for MinIO connectivity (with timeout); if restore fails and no cached backup exists, service starts with empty database
- What happens when MinIO is unavailable during runtime?
  - Litestream continues attempting replication; database remains functional locally, changes queue until MinIO recovers
- How does the system handle Overseerr failing to connect to Plex/Sonarr/Radarr?
  - Overseerr displays connection errors in its UI; the service continues running to allow reconfiguration
- What happens if the litestream seed fails during migration?
  - Administrator should verify MinIO connectivity, check credentials, and retry; if persistent failure, manually copy database file to ephemeral disk location as fallback
- What happens if Hestia (hosting Sonarr/Radarr) is down?
  - Overseerr remains running but cannot fulfill requests; connection errors displayed in UI until Hestia recovers
- What happens if database becomes corrupted?
  - Litestream maintains point-in-time recovery; administrator can restore to a previous snapshot

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST deploy Overseerr as a Nomad job using the `sctx/overseerr:latest` container image
- **FR-002**: System MUST expose the Overseerr web UI on port 5055 via Consul Connect service mesh
- **FR-003**: System MUST configure Traefik ingress to route `overseerr.brmartin.co.uk` to the Overseerr service with HTTPS
- **FR-004**: System MUST use ephemeral disk with sticky allocation for SQLite database storage (NOT network filesystem)
- **FR-005**: System MUST NOT constrain the job to a specific node, allowing Nomad to schedule on any available node for failover
- **FR-006**: System MUST enable transparent proxy mode in Consul Connect to allow outbound network connectivity from the container
- **FR-007**: System MUST include a health check endpoint for service discovery
- **FR-008**: System MUST set the timezone environment variable to `Europe/London` for consistent scheduling and logging
- **FR-009**: System MUST run a litestream restore prestart task to recover database from MinIO before Overseerr starts
- **FR-010**: System MUST run a litestream replicate sidecar to continuously backup database changes to MinIO
- **FR-011**: System MUST provision a GlusterFS CSI volume for non-database configuration files (settings.json, logs)
- **FR-012**: Migration MUST preserve all existing data from docker-compose deployment including user accounts, request history, and integration settings
- **FR-013**: Migration MUST seed the litestream backup in MinIO from the existing SQLite database before first Nomad deployment
- **FR-014**: Migration MUST copy settings.json from docker-compose volume to GlusterFS CSI volume

### Integration Configuration

Overseerr connects to backend services via direct IP since Sonarr and Radarr remain on docker-compose (not in Consul mesh):

- **Sonarr**: `http://192.168.1.5:<sonarr-port>` (configured in Overseerr UI post-deployment)
- **Radarr**: `http://192.168.1.5:<radarr-port>` (configured in Overseerr UI post-deployment)
- **Plex**: `http://192.168.1.5:32400` or via `plex.brmartin.co.uk` (Plex is in Consul mesh)
- **MinIO**: `http://minio-minio.virtual.consul:9000` (for litestream replication via Consul mesh)

### Key Entities

- **Overseerr Service**: Web application for media request management
  - Exposes HTTP on port 5055
  - SQLite database stored on ephemeral disk, replicated via litestream
  - Configuration files (settings.json) on GlusterFS volume
  - Communicates with Plex, Sonarr, Radarr via direct IP
  
- **Litestream Restore Task**: Prestart lifecycle task
  - Restores SQLite database from MinIO before main task starts
  - Skips restore if database already exists on ephemeral disk (sticky allocation)
  
- **Litestream Sidecar**: Poststart lifecycle sidecar
  - Continuously replicates SQLite WAL changes to MinIO
  - Bucket: `overseerr-litestream` (to be created in MinIO)
  
- **CSI Volume**: GlusterFS-backed persistent storage
  - Named `glusterfs_overseerr_config`
  - Single-node-writer access mode
  - Mounted for settings.json and logs only (NOT database)
  
- **Traefik Router**: HTTPS ingress configuration
  - Routes `overseerr.brmartin.co.uk` to the Consul Connect service
  - Uses websecure entrypoint with automatic certificate management

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can access Overseerr at `https://overseerr.brmartin.co.uk` and authenticate within 5 seconds of page load
- **SC-002**: Media requests submitted through Overseerr appear in Sonarr/Radarr within 30 seconds
- **SC-003**: Service maintains 99% uptime during normal cluster operations (excluding planned maintenance)
- **SC-004**: Configuration and request data survives service restarts with zero data loss
- **SC-005**: Service successfully starts within 2 minutes of job submission to Nomad
- **SC-006**: Service successfully reschedules to another node within 5 minutes when the original node fails
- **SC-007**: Database changes are replicated to MinIO within 5 minutes of occurrence
- **SC-008**: Database can be fully restored from MinIO backup in under 60 seconds
- **SC-009**: Migration preserves 100% of user accounts from docker-compose deployment
- **SC-010**: Migration preserves 100% of request history from docker-compose deployment
- **SC-011**: Migration downtime is less than 10 minutes
- **SC-012**: All integrations (Plex, Sonarr, Radarr) work without reconfiguration after migration

## Assumptions

- Sonarr and Radarr remain on docker-compose on Hestia (192.168.1.5) and are accessible via direct IP from any cluster node
- Plex is deployed on Nomad and accessible via Consul mesh (plex.brmartin.co.uk) or direct IP
- MinIO is deployed and accessible via Consul mesh for litestream backup storage
- The GlusterFS CSI plugin is already deployed and operational in the cluster
- Traefik is configured to discover services from Consul Catalog
- The existing docker-compose deployment on Hestia contains production data that must be migrated (see User Story 6)
- Docker-compose Overseerr can be stopped during migration window (planned downtime acceptable)
- Network connectivity exists between all cluster nodes and Hestia (192.168.1.5)
- Vault contains or will contain MinIO credentials for the Overseerr litestream configuration
