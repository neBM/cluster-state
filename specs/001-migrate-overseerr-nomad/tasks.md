# Tasks: Migrate Overseerr to Nomad

**Input**: Design documents from `/specs/001-migrate-overseerr-nomad/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Not explicitly requested - manual verification via Nomad UI, health checks, and Elasticsearch logs per plan.md

**Organization**: Tasks grouped by user story. Note that for this IaC project, most user stories are satisfied by the same infrastructure code - the grouping reflects verification and configuration concerns.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- All file paths are absolute from repository root

---

## Phase 1: Setup (Terraform Module Structure)

**Purpose**: Create the Terraform module directory and basic structure

- [x] T001 Create module directory at modules/overseerr/
- [x] T002 Create main.tf with GlusterFS plugin data source in modules/overseerr/main.tf
- [x] T003 Create empty jobspec.nomad.hcl skeleton in modules/overseerr/jobspec.nomad.hcl
- [x] T004 Add module reference in root main.tf

---

## Phase 2: Foundational (CSI Volume & Job Structure)

**Purpose**: Core infrastructure that MUST be complete before user stories can be verified

**⚠️ CRITICAL**: All user stories depend on the Nomad job being deployable

- [x] T005 Define CSI volume resource glusterfs_overseerr_config in modules/overseerr/main.tf
- [x] T006 Define nomad_job resource with depends_on for CSI volume in modules/overseerr/main.tf
- [x] T007 Create job block with datacenter and namespace in modules/overseerr/jobspec.nomad.hcl
- [x] T008 Create group block with network (bridge mode, port 5055) in modules/overseerr/jobspec.nomad.hcl
- [x] T009 Add ephemeral_disk block (sticky, migrate, 100MB) in modules/overseerr/jobspec.nomad.hcl
- [x] T010 Add volume block for CSI volume attachment in modules/overseerr/jobspec.nomad.hcl

**Checkpoint**: Module structure complete - can run `terraform plan` to validate syntax

---

## Phase 3: User Story 6 - Data Migration (Priority: P1) 🎯 MVP-FIRST

**Goal**: Migrate existing data from docker-compose before Nomad deployment

**Independent Test**: After seeding, verify `mc ls minio/overseerr-litestream/db/` shows litestream generations

**Why First**: Migration must happen BEFORE first Nomad deployment to preserve production data

### Implementation for User Story 6

- [ ] T011 [US6] Create pre-migration backup script documentation in specs/001-migrate-overseerr-nomad/quickstart.md (verify backup command)
- [ ] T012 [US6] SSH to Hestia and create backup of docker-compose data: `/var/lib/docker/volumes/downloads_config-overseerr/_data/`
- [ ] T013 [US6] Stop docker-compose Overseerr on Hestia: `docker stop overseerr`
- [ ] T014 [US6] Seed litestream backup to MinIO using one-time replicate command (per quickstart.md)
- [ ] T015 [US6] Verify litestream seed successful: `mc ls minio/overseerr-litestream/db/`
- [ ] T016 [US6] Apply Terraform to create CSI volume (partial apply): `terraform apply -target=module.overseerr.nomad_csi_volume.glusterfs_overseerr_config`
- [ ] T017 [US6] Copy settings.json to GlusterFS volume: `/storage/v/overseerr_config/settings.json`
- [ ] T018 [US6] Verify settings.json copied correctly with correct permissions

**Checkpoint**: Data migration complete - existing data preserved in MinIO and GlusterFS

---

## Phase 4: User Story 5 - Database Backup and Recovery (Priority: P1)

**Goal**: Implement litestream restore and replication tasks in the Nomad job

**Independent Test**: After deployment, verify `nomad alloc logs $ALLOC litestream` shows replication activity

### Implementation for User Story 5

- [x] T019 [US5] Add litestream-restore prestart task with lifecycle hook in modules/overseerr/jobspec.nomad.hcl
- [x] T020 [US5] Add litestream-restore shell script to check for existing DB, wait for proxy, restore from MinIO in modules/overseerr/jobspec.nomad.hcl
- [x] T021 [US5] Add litestream-restore Vault template for MinIO credentials (nomad/default/overseerr) in modules/overseerr/jobspec.nomad.hcl
- [x] T022 [US5] Add litestream-restore resources block (cpu=100, memory=256, memory_max=512) in modules/overseerr/jobspec.nomad.hcl
- [x] T023 [US5] Add litestream sidecar task with poststart lifecycle hook in modules/overseerr/jobspec.nomad.hcl
- [x] T024 [US5] Add litestream sidecar replicate configuration with sync-interval, snapshot-interval, retention in modules/overseerr/jobspec.nomad.hcl
- [x] T025 [US5] Add litestream sidecar Vault template for MinIO credentials in modules/overseerr/jobspec.nomad.hcl
- [x] T026 [US5] Add litestream sidecar resources block (cpu=100, memory=128, memory_max=256) in modules/overseerr/jobspec.nomad.hcl

**Checkpoint**: Litestream tasks defined - database will be restored on startup and continuously replicated

---

## Phase 5: User Story 1 - Access Overseerr Web UI (Priority: P1)

**Goal**: Deploy Overseerr main task with Traefik ingress for HTTPS access

**Independent Test**: Navigate to `https://overseerr.brmartin.co.uk` and verify login page loads

### Implementation for User Story 1

- [x] T027 [US1] Add overseerr main task with docker driver and image sctx/overseerr:latest in modules/overseerr/jobspec.nomad.hcl
- [x] T028 [US1] Add volume_mount for CSI volume at /app/config in modules/overseerr/jobspec.nomad.hcl
- [x] T029 [US1] Add bind mount from /alloc/data/db to /app/config/db for ephemeral SQLite in modules/overseerr/jobspec.nomad.hcl
- [x] T030 [US1] Add env block with TZ=Europe/London in modules/overseerr/jobspec.nomad.hcl
- [x] T031 [US1] Add resources block (cpu=200, memory=256, memory_max=512) in modules/overseerr/jobspec.nomad.hcl
- [x] T032 [US1] Add service block with Consul provider, port 5055 in modules/overseerr/jobspec.nomad.hcl
- [x] T033 [US1] Add health check (HTTP GET /api/v1/status, interval=30s, timeout=5s, expose=true) in modules/overseerr/jobspec.nomad.hcl
- [x] T034 [US1] Add Consul Connect sidecar_service with transparent_proxy in modules/overseerr/jobspec.nomad.hcl
- [x] T035 [US1] Add Traefik tags for Host(`overseerr.brmartin.co.uk`), websecure entrypoint in modules/overseerr/jobspec.nomad.hcl

**Checkpoint**: Web UI accessible via HTTPS - core user-facing functionality complete

---

## Phase 6: User Story 2 - Configuration Persistence (Priority: P1)

**Goal**: Ensure settings.json and logs persist on GlusterFS volume

**Independent Test**: Stop and restart Nomad job, verify settings preserved in Overseerr UI

### Implementation for User Story 2

- [x] T036 [US2] Verify volume_mount paths correctly separate db (ephemeral) from config (CSI) in modules/overseerr/jobspec.nomad.hcl
- [x] T037 [US2] Ensure CSI volume has prevent_destroy lifecycle in modules/overseerr/main.tf
- [x] T038 [US2] Add logs directory handling if needed (verify Overseerr creates logs/ automatically)

**Checkpoint**: Configuration persists across restarts - no data loss on redeployment

---

## Phase 7: User Story 3 - Media Service Integration (Priority: P1)

**Goal**: Ensure Overseerr can reach Sonarr, Radarr, and Plex via transparent proxy

**Independent Test**: In Overseerr UI, verify Plex/Sonarr/Radarr connections show "Connected"

### Implementation for User Story 3

- [x] T039 [US3] Verify transparent_proxy block enables outbound connectivity in modules/overseerr/jobspec.nomad.hcl
- [x] T040 [US3] Document integration URLs in quickstart.md: Sonarr (192.168.1.5:8989), Radarr (192.168.1.5:7878), Plex (192.168.1.5:32400)
- [ ] T041 [US3] Post-deployment: Configure Sonarr integration in Overseerr UI with API key
- [ ] T042 [US3] Post-deployment: Configure Radarr integration in Overseerr UI with API key
- [ ] T043 [US3] Post-deployment: Verify Plex integration (should work from migrated settings.json)

**Checkpoint**: All media service integrations functional - requests flow to Sonarr/Radarr

---

## Phase 8: User Story 4 - Flexible Node Scheduling (Priority: P2)

**Goal**: Ensure no node constraints allow failover across cluster

**Independent Test**: Drain current node, verify job reschedules and remains functional

### Implementation for User Story 4

- [x] T044 [US4] Verify NO constraint blocks in group or job level in modules/overseerr/jobspec.nomad.hcl
- [x] T045 [US4] Verify image sctx/overseerr:latest supports multi-arch (amd64, arm64) - already confirmed in research.md
- [ ] T046 [US4] Test failover: Drain node running Overseerr, verify reschedule to another node
- [ ] T047 [US4] Test connectivity: After reschedule, verify Sonarr/Radarr reachable via 192.168.1.5

**Checkpoint**: High availability verified - service survives node failure

---

## Phase 9: Deployment & Verification

**Purpose**: Full deployment and validation of all user stories

- [ ] T048 Run terraform plan for full module: `terraform plan -target=module.overseerr -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan`
- [ ] T049 Review plan output, verify CSI volume and job resources
- [ ] T050 Apply terraform: `terraform apply tfplan`
- [ ] T051 Verify job status: `nomad job status overseerr`
- [ ] T052 Verify litestream-restore logs show successful restore
- [ ] T053 Verify overseerr task is running and healthy
- [ ] T054 Verify litestream sidecar shows replication activity
- [ ] T055 Access https://overseerr.brmartin.co.uk and verify login page (US1)
- [ ] T056 Verify migrated user accounts can log in (US6)
- [ ] T057 Verify request history preserved (US6)
- [ ] T058 Verify Plex/Sonarr/Radarr integrations work (US3)
- [ ] T059 Submit test request, verify appears in Sonarr/Radarr (US3)
- [ ] T060 Stop and restart job, verify data persists (US2, US5)
- [ ] T061 Check MinIO bucket for litestream generations: `mc ls minio/overseerr-litestream/db/` (US5)

**Checkpoint**: All user stories verified - deployment complete

---

## Phase 10: Polish & Cleanup

**Purpose**: Post-deployment cleanup and documentation

- [ ] T062 Wait 24 hours verification period before cleanup
- [ ] T063 Remove docker-compose Overseerr container on Hestia: `docker rm overseerr`
- [ ] T064 Update docker-compose.yml on Hestia to remove Overseerr service definition
- [ ] T065 Update AGENTS.md if any new operational patterns discovered
- [ ] T066 Commit all changes with descriptive message

---

## Dependencies & Execution Order

### Phase Dependencies

```
Phase 1: Setup ─────────────────────────────────────────────────────────┐
    │                                                                    │
    ▼                                                                    │
Phase 2: Foundational (CSI Volume & Job Structure) ─────────────────────┤
    │                                                                    │
    ▼                                                                    │
Phase 3: US6 - Data Migration ◄─── MUST complete before first deploy    │
    │                                                                    │
    ├──────────────────────────────────────────────────────────────────┐ │
    │                                                                  │ │
    ▼                                                                  ▼ │
Phase 4: US5 - Litestream ──────► Phase 5: US1 - Web UI               │ │
    │                                  │                               │ │
    │                                  ▼                               │ │
    │                             Phase 6: US2 - Persistence           │ │
    │                                  │                               │ │
    │                                  ▼                               │ │
    └──────────────────────────► Phase 7: US3 - Integrations           │ │
                                       │                               │ │
                                       ▼                               │ │
                                  Phase 8: US4 - Failover (P2) ◄───────┘ │
                                       │                                 │
                                       ▼                                 │
                                  Phase 9: Deployment ◄──────────────────┘
                                       │
                                       ▼
                                  Phase 10: Cleanup
```

### User Story Independence

| Story | Can Start After | Dependencies on Other Stories |
|-------|----------------|-------------------------------|
| US6 (Migration) | Phase 2 | None - MUST be first |
| US5 (Backup) | Phase 2 + US6 | US6 provides initial data |
| US1 (Web UI) | Phase 2 | None for code, US6 for data |
| US2 (Persistence) | US1 | Builds on US1 volume config |
| US3 (Integration) | US1 | Needs running service |
| US4 (Failover) | US1, US5 | Needs full deployment |

### Parallel Opportunities

**Phase 1-2**: Sequential (project setup)

**Phase 4-5**: Can work on litestream tasks (T019-T026) in parallel with main task definition (T027-T035) since they're in the same file but different task blocks

**Phase 9**: Verification tasks T055-T061 are sequential (require running service)

---

## Parallel Example: Litestream + Main Task

```bash
# These can be developed in parallel (different task blocks in same file):
# Developer A: Litestream restore task (T019-T022)
# Developer B: Litestream sidecar task (T023-T026)  
# Developer C: Overseerr main task (T027-T035)

# Then integrate and test together
```

---

## Implementation Strategy

### MVP First (Migration + Core Deployment)

1. Complete Phase 1: Setup (T001-T004)
2. Complete Phase 2: Foundational (T005-T010)
3. Complete Phase 3: Data Migration (T011-T018) **← Critical: preserves production data**
4. Complete Phase 4: Litestream (T019-T026)
5. Complete Phase 5: Web UI (T027-T035)
6. **STOP and VALIDATE**: Deploy and verify basic access works
7. If issues: Rollback using `docker start overseerr` on Hestia

### Incremental Verification

After each phase checkpoint, verify:
- `terraform plan` shows expected changes
- `terraform apply` succeeds
- `nomad job status overseerr` shows healthy allocation
- Relevant user story acceptance criteria pass

### Rollback Plan

At any point before T062-T064 (cleanup):
1. `nomad job stop overseerr`
2. `ssh 192.168.1.5 "docker start overseerr"`
3. Docker-compose Overseerr resumes with original data

---

## Notes

- All tasks include exact file paths
- Migration (US6) must complete before first Nomad deployment
- Vault secret and MinIO bucket already exist (per quickstart.md)
- [P] marks tasks that can run in parallel within their phase
- [USx] marks which user story the task supports
- Commit after each phase completion for easy rollback
- Keep docker-compose data for 24+ hours after successful migration
