# Tasks: GitLab Multi-Container Migration

**Input**: Design documents from `/specs/008-gitlab-multi-container/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Manual verification only (no automated tests requested)

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Terraform Module**: `modules-k8s/gitlab/`
- **Files**: `main.tf`, `variables.tf`, `secrets.tf`, `outputs.tf`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare the module structure and extract required secrets

- [X] T001 Backup current GitLab module by copying modules-k8s/gitlab/ to modules-k8s/gitlab-omnibus-backup/
- [X] T002 [P] Extract secrets from running Omnibus container to /tmp/gitlab-secrets.json
- [X] T003 [P] Generate new tokens (workhorse secret, gitaly token, shell secret) and store temporarily
- [X] T004 Update variables.tf with CNG image variables in modules-k8s/gitlab/variables.tf

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Create PVC resources for gitlab-repositories in modules-k8s/gitlab/main.tf
- [X] T006 [P] Create PVC resources for gitlab-uploads in modules-k8s/gitlab/main.tf
- [X] T007 [P] Create PVC resources for gitlab-shared in modules-k8s/gitlab/main.tf
- [X] T008 [P] Create PVC resources for gitlab-registry in modules-k8s/gitlab/main.tf
- [X] T009 Create gitlab-rails-secret via kubectl (NOT in Terraform to avoid secrets in git)
- [X] T010 [P] Create gitlab-workhorse Secret via kubectl
- [X] T011 [P] Create gitlab-gitaly Secret via kubectl
- [X] T012 [P] Create gitlab-shell Secret via kubectl
- [X] T013 [P] Create gitlab-registry-auth Secret via kubectl
- [X] T014 Create ConfigMap gitlab-config-templates with gitlab.yml, database.yml, resque.yml in modules-k8s/gitlab/main.tf
- [X] T015 [P] Create ConfigMap gitaly-config with config.toml in modules-k8s/gitlab/main.tf
- [X] T016 [P] Create ConfigMap workhorse-config with workhorse-config.toml in modules-k8s/gitlab/main.tf
- [X] T017 Create Redis Deployment and Service (gitlab-redis) in modules-k8s/gitlab/main.tf

**Checkpoint**: Foundation ready - PVCs, Secrets, ConfigMaps, and Redis deployed ✅

---

## Phase 3: User Story 1 - Data Preservation During Migration (Priority: P1) 🎯 MVP

**Goal**: Migrate existing data to new PVC structure while preserving all repositories, users, and configurations

**Independent Test**: Clone existing repositories, verify access tokens work, check CI pipelines are intact

### Implementation for User Story 1

- [X] T018 [US1] Stop current Omnibus GitLab deployment (scale replicas to 0) via terraform
- [X] T019 [US1] Run data migration: copy repositories to gitlab-repositories PVC directory
- [X] T020 [US1] Run data migration: copy uploads to gitlab-uploads PVC directory
- [X] T021 [US1] Run data migration: copy shared data to gitlab-shared PVC directory
- [X] T022 [US1] Run data migration: copy registry data to gitlab-registry PVC directory
- [X] T023 [US1] Set correct ownership (UID 1000) on all PVC directories

**Checkpoint**: All data migrated to new PVC locations with correct permissions ✅

---

## Phase 4: User Story 2 - Core GitLab Functionality (Priority: P1)

**Goal**: Deploy all CNG containers so GitLab web UI, git operations, and CI/CD work

**Independent Test**: Access web UI, push/pull via HTTPS, trigger CI pipeline, push/pull container images

### Implementation for User Story 2

- [X] T024 [US2] Create Gitaly Deployment in modules-k8s/gitlab/main.tf
- [X] T025 [US2] Create Gitaly Service (gitlab-gitaly:8075) in modules-k8s/gitlab/main.tf
- [X] T026 [US2] Create Webservice Deployment in modules-k8s/gitlab/main.tf
- [X] T027 [US2] Create Webservice Service (gitlab-webservice:8080) in modules-k8s/gitlab/main.tf
- [X] T028 [US2] Create Workhorse Deployment in modules-k8s/gitlab/main.tf
- [X] T029 [US2] Create Workhorse Service (gitlab-workhorse:8181) in modules-k8s/gitlab/main.tf
- [X] T030 [US2] Create Sidekiq Deployment in modules-k8s/gitlab/main.tf
- [X] T031 [US2] Create Registry Deployment in modules-k8s/gitlab/main.tf
- [X] T032 [US2] Create Registry Service (gitlab-registry:5000) in modules-k8s/gitlab/main.tf
- [X] T033 [US2] Update IngressRoute for gitlab to point to gitlab-workhorse service in modules-k8s/gitlab/main.tf
- [X] T034 [US2] Update IngressRoute for registry to point to gitlab-registry service in modules-k8s/gitlab/main.tf
- [X] T035 [US2] Apply terraform and verify all pods are running

**Checkpoint**: GitLab fully functional - web UI accessible, git operations work, CI/CD functional ✅

---

## Phase 5: User Story 3 - Service Isolation and Single Responsibility (Priority: P2)

**Goal**: Verify each component runs independently and can be managed separately

**Independent Test**: Restart individual components, verify others continue functioning, check component-specific logs

### Implementation for User Story 3

- [X] T036 [US3] Add component labels (app=gitlab, component=X) to all Deployments in modules-k8s/gitlab/main.tf
- [X] T037 [US3] Configure health checks (readiness/liveness probes) for Webservice in modules-k8s/gitlab/main.tf
- [X] T038 [P] [US3] Configure health checks for Workhorse in modules-k8s/gitlab/main.tf
- [X] T039 [P] [US3] Configure health checks for Gitaly in modules-k8s/gitlab/main.tf
- [X] T040 [P] [US3] Configure health checks for Sidekiq in modules-k8s/gitlab/main.tf
- [X] T041 [P] [US3] Configure health checks for Redis in modules-k8s/gitlab/main.tf
- [X] T042 [P] [US3] Configure health checks for Registry in modules-k8s/gitlab/main.tf
- [X] T043 [US3] Verify graceful degradation by restarting Sidekiq (web UI should remain accessible)

**Checkpoint**: All components independently manageable with proper health checks ✅

---

## Phase 6: User Story 4 - External Service Integration (Priority: P2)

**Goal**: Verify external PostgreSQL is used and Redis container is properly integrated

**Independent Test**: Check database connections point to 192.168.1.10:5433, verify Redis connectivity from all components

### Implementation for User Story 4

- [X] T044 [US4] Verify database.yml ConfigMap points to external PostgreSQL (192.168.1.10:5433) in modules-k8s/gitlab/main.tf
- [X] T045 [US4] Verify resque.yml ConfigMap points to gitlab-redis service in modules-k8s/gitlab/main.tf
- [X] T046 [US4] Verify no embedded PostgreSQL by checking Webservice container has no postgres process
- [X] T047 [US4] Test Redis connectivity from Webservice pod using redis-cli

**Checkpoint**: External PostgreSQL confirmed, Redis container properly integrated ✅

---

## Phase 7: User Story 5 - Migration Execution (Priority: P3)

**Goal**: Document and validate the complete migration procedure

**Independent Test**: Review quickstart.md, verify all steps were executed successfully

### Implementation for User Story 5

- [X] T048 [US5] Update quickstart.md with actual paths and commands used in specs/008-gitlab-multi-container/quickstart.md
- [X] T049 [US5] Run full verification checklist from quickstart.md
- [X] T050 [US5] Document any deviations or issues encountered during migration

**Checkpoint**: Migration procedure documented and validated ✅

### Key Issues Encountered and Resolved

1. **database.yml missing `ci:` section** - GitLab 17.0+ requires both `main:` and `ci:` database configs (with `database_tasks: false` for ci)
2. **gitlab.yml IPv6 YAML parsing** - IPv6 addresses in trusted_proxies need quoting (`"::1/128"`)
3. **Sidekiq missing workhorse-secret** - Required volume mount was initially omitted
4. **Registry health checks** - Changed from HTTP to TCP probes (registry returns 401 on /v2/ without auth)
5. **CNG secrets path** - Secrets must be mounted to `/srv/gitlab/config/secrets.yml` (hardcoded in `initializers/2_secret_token.rb`), not `/etc/gitlab/rails-secrets/`
6. **Secrets YAML format** - `active_record_encryption` keys must be flat (`active_record_encryption_primary_key`) not nested (`active_record_encryption.primary_key`)

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Cleanup and finalization

- [X] T051 Remove old Omnibus deployment resources from modules-k8s/gitlab/main.tf
- [X] T052 [P] Update outputs.tf with new service endpoints in modules-k8s/gitlab/outputs.tf
- [X] T053 [P] Update AGENTS.md with new GitLab architecture notes
- [X] T054 Clean up temporary files (/tmp/gitlab-secrets.json, generated tokens)
- [X] T055 Remove backup directory modules-k8s/gitlab-omnibus-backup/ after confirming success
- [X] T056 Final terraform plan to verify clean state
- [X] T057 Increase webservice memory limit to 3Gi (was OOMKilled at 2Gi)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational - data migration
- **User Story 2 (Phase 4)**: Depends on User Story 1 - containers need migrated data
- **User Story 3 (Phase 5)**: Depends on User Story 2 - need running containers to verify isolation
- **User Story 4 (Phase 6)**: Depends on User Story 2 - need running containers to verify connections
- **User Story 5 (Phase 7)**: Depends on User Stories 3 & 4 - document after validation
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P1)**: Depends on User Story 1 (data must be migrated before containers start)
- **User Story 3 (P2)**: Depends on User Story 2 (containers must be running)
- **User Story 4 (P2)**: Depends on User Story 2 (containers must be running) - Can run in parallel with US3
- **User Story 5 (P3)**: Depends on User Stories 3 & 4 (need complete working system)

### Within Each Phase

- Tasks marked [P] can run in parallel within their phase
- ConfigMaps before Deployments
- Secrets before Deployments that reference them
- Services created with their Deployments

### Parallel Opportunities

**Phase 2 (Foundational)**:
```
Parallel Group 1: T006, T007, T008 (PVCs)
Parallel Group 2: T010, T011, T012, T013 (Secrets)
Parallel Group 3: T015, T016 (ConfigMaps)
```

**Phase 5 (User Story 3)**:
```
Parallel Group: T038, T039, T040, T041, T042 (Health checks)
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2)

1. Complete Phase 1: Setup (backup, extract secrets)
2. Complete Phase 2: Foundational (PVCs, Secrets, ConfigMaps, Redis)
3. Complete Phase 3: User Story 1 (data migration)
4. Complete Phase 4: User Story 2 (deploy containers)
5. **STOP and VALIDATE**: Test GitLab is fully functional
6. This is the MVP - GitLab works with multi-container architecture

### Full Delivery

1. Complete MVP (Phases 1-4)
2. Add User Story 3 (service isolation verification)
3. Add User Story 4 (external service verification) - can run in parallel with US3
4. Add User Story 5 (documentation)
5. Complete Polish phase

### Rollback Plan

If migration fails at any point:
1. Scale down new deployments
2. Restore old Omnibus deployment from backup
3. Data in PVCs is preserved (reclaimPolicy: Retain)

---

## Notes

- [P] tasks = different files or independent operations
- [Story] label maps task to specific user story for traceability
- This is an infrastructure migration - "tests" are manual verification steps
- Data migration (US1) must complete before container deployment (US2)
- Downtime is acceptable - no need for blue/green deployment
- All terraform operations should use `-target` for incremental changes during migration
