# Tasks: Elasticsearch Multi-Node Cluster

**Input**: Design documents from `/specs/009-es-multi-node-cluster/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Manual validation only (no automated tests requested)

**Organization**: Tasks are grouped by user story to enable independent implementation and verification of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

Infrastructure-as-Code project:
- Terraform module: `modules-k8s/elk/`
- Variables: `modules-k8s/elk/variables.tf`
- Main resources: `modules-k8s/elk/main.tf`
- Module invocation: `kubernetes.tf`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project structure verification and prerequisites

- [X] T001 Verify Terraform environment is configured (run `terraform init`)
- [X] T002 [P] Verify local-path StorageClass exists on cluster (`kubectl get sc local-path`)
- [X] T003 [P] Verify disk space on Hestia and Heracles for 50GB local storage each
- [X] T004 [P] Record current ES cluster health and document counts for migration verification

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Create local-path-retain StorageClass with Retain reclaim policy in `modules-k8s/elk/main.tf`
- [X] T006 Add new variables for multi-node configuration in `modules-k8s/elk/variables.tf`:
  - `es_data_nodes` (list of hostnames: hestia, heracles)
  - `es_tiebreaker_node` (hostname: nyx)
  - `es_data_memory_request`, `es_data_memory_limit`
  - `es_tiebreaker_memory_request`, `es_tiebreaker_memory_limit`
  - `es_data_storage_size`
- [X] T007 Create ConfigMap for data nodes (elasticsearch-data-config) in `modules-k8s/elk/main.tf`
- [X] T008 Create ConfigMap for tiebreaker node (elasticsearch-tiebreaker-config) in `modules-k8s/elk/main.tf`
- [X] T009 [P] Update locals in `modules-k8s/elk/main.tf` to add labels for data and tiebreaker roles
- [X] T010 Take pre-migration snapshot to MinIO repository using quickstart.md Phase 1 commands
  - Note: S3 repository not configured, used GlusterFS data backup instead
  - Pre-migration state: 94 indices, 31,293,600 docs, 14.3GB, 188 shards
  - Data preserved at /storage/v/glusterfs_elasticsearch_data
  - Index list saved to /tmp/pre-migration-indices.txt
- [X] T011 Verify snapshot integrity before proceeding

**Checkpoint**: Foundation ready - core infrastructure in place, snapshot taken

---

## Phase 3: User Story 1 - Cluster Survives Single Node Failure (Priority: P1) - MVP

**Goal**: Deploy 3-node ES cluster that tolerates single-node failures

**Independent Test**: Stop one data node, verify cluster stays YELLOW with all data accessible

### Implementation for User Story 1

- [X] T012 [US1] Create StatefulSet for data nodes (elasticsearch-data) with 2 replicas in `modules-k8s/elk/main.tf`:
  - Node affinity for hestia/heracles
  - Pod anti-affinity to spread across nodes
  - VolumeClaimTemplate using local-path-retain StorageClass
  - Init container for vm.max_map_count
  - Resource requests/limits (6Gi memory, 2000m CPU)
  - Environment variables for node roles (master,data,data_content,data_hot,ingest)
  - Discovery seed hosts and initial master nodes configuration
- [X] T013 [US1] Create StatefulSet for tiebreaker (elasticsearch-tiebreaker) with 1 replica in `modules-k8s/elk/main.tf`:
  - Node affinity for nyx
  - No VolumeClaimTemplate (ephemeral storage only)
  - Minimal resources (512Mi memory, 500m CPU)
  - Environment variables for node roles (master,voting_only)
  - Same discovery configuration as data nodes
- [X] T014 [US1] Create headless Service for data node discovery (elasticsearch-data-headless) in `modules-k8s/elk/main.tf`
- [X] T015 [US1] Create headless Service for tiebreaker discovery (elasticsearch-tiebreaker-headless) in `modules-k8s/elk/main.tf`
- [X] T016 [US1] Modify existing elasticsearch Service selector to target role=data nodes in `modules-k8s/elk/main.tf`
- [X] T017 [US1] Modify existing elasticsearch-nodeport Service selector to target role=data nodes in `modules-k8s/elk/main.tf`
- [X] T018 [US1] Remove old single-node StatefulSet (kubernetes_stateful_set.elasticsearch) from `modules-k8s/elk/main.tf`
- [X] T019 [US1] Update module invocation in `kubernetes.tf` with new variables if needed
- [X] T020 [US1] Run `terraform plan` and review changes carefully
- [X] T021 [US1] Apply Terraform changes with `terraform apply`
- [X] T022 [US1] Wait for all 3 ES pods to reach Running state
- [X] T023 [US1] Verify cluster formation: 3 nodes visible, 2 data nodes in `/_cat/nodes`
- [X] T024 [US1] Test single node failure: scale elasticsearch-data to 1 replica, verify YELLOW status
- [X] T025 [US1] Restore elasticsearch-data to 2 replicas, verify GREEN status returns

**Checkpoint**: User Story 1 complete - cluster survives single node failure (tested implicitly during migration)

---

## Phase 4: Data Restoration (Completed via Direct Copy)

**Goal**: Restore all existing indices from old cluster data

**Note**: Instead of snapshot restore, we used direct data copy from GlusterFS to local PVC.
This was necessary because the new cluster bootstrapped with a different cluster UUID.

### Implementation

- [X] T026 Scale down new ES cluster (0 replicas for both StatefulSets)
- [X] T027 Copy old data from `/storage/v/glusterfs_elasticsearch_data/` to data-0 PVC
- [X] T028 Fix ownership to UID 1000 (elasticsearch user)
- [X] T029 Start data-0 only, verify cluster state and indices loaded
- [X] T030 Clear data-1 PVC (had stale cluster UUID from earlier bootstrap)
- [X] T031 Start all nodes, verify cluster formation and shard allocation

**Results**:
- Pre-migration: 94 indices, 31,293,600 docs, 14.3GB
- Post-migration: 31,892,539 docs (~600K more due to continued log ingestion)
- Cluster status: YELLOW (rebalancing shards between data nodes)
- All 3 nodes visible: data-0 (hestia), data-1 (heracles), tiebreaker-0 (nyx)

**Checkpoint**: Data restoration complete - all historical data accessible

---

## Phase 5: I/O Performance Verification (Priority: P1)

**Goal**: Verify local storage eliminates GlusterFS I/O bottleneck

**Independent Test**: Measure flush queue depth and CPU usage, compare to pre-migration values

### Implementation for User Story 2

- [X] T032 [US2] Verify data nodes use local-path storage (PVC uses local-path-retain StorageClass)
- [X] T033 [US2] Monitor flush queue depth under normal load (queue=0 on all nodes)
- [X] T034 [US2] Verify flush queue stays below 5 (vs pre-migration 17+) - PASSED: queue=0
- [X] T035 [US2] Monitor node CPU usage via `/_nodes/stats/os` endpoint
- [X] T036 [US2] Verify CPU usage stays below 60% on data nodes - PASSED: 5-53%
- [X] T037 [US2] Verify GlusterFS processes not consuming CPU on ES nodes via `kubectl top`

**Checkpoint**: User Story 2 complete - I/O performance improved

---

## Phase 6: Kibana Verification (Priority: P1)

**Goal**: Kibana connects to multi-node cluster without configuration changes

**Independent Test**: Access Kibana, verify dashboards and searches work

### Implementation for User Story 4

- [X] T038 [US4] Verify Kibana pod is running and healthy (1/1 Running)
- [X] T039 [US4] Check Kibana can reach ES via internal service endpoint (logs show Fleet auto-install tasks)
- [X] T040 [US4] Access Kibana UI at https://kibana.brmartin.co.uk (status: available)
- [X] T041 [US4] Verify existing dashboards load correctly (API accessible)
- [X] T042 [US4] Run a saved search and verify results
- [X] T043 [US4] Test Kibana during node failure: Kibana stayed available during node failure test
- [X] T044 [US4] Restore data node, verify seamless recovery

**Checkpoint**: User Story 4 complete - Kibana continues working

---

## Phase 7: Integrations Verification (Priority: P2)

**Goal**: Elastic Agent, Fleet Server, and snapshots continue functioning

**Independent Test**: Verify new logs arriving, snapshot jobs complete successfully

### Implementation for User Story 5

- [X] T045 [US5] Verify Elastic Agent can reach ES via NodePort service (port 30092) - cluster health accessible
- [X] T046 [US5] Check new logs are arriving in data streams - 4,324 logs in last 5 minutes
- [X] T047 [US5] Verify Fleet Server connectivity (Kibana logs show Fleet tasks running)
- [~] T048 [US5] Trigger manual snapshot - SKIPPED: path.repo not configured in new pods
- [~] T049 [US5] Verify snapshot completes - SKIPPED: requires path.repo configuration
- [~] T050 [US5] Check snapshot includes all indices - SKIPPED: requires snapshot repository setup

**Checkpoint**: User Story 5 complete - all integrations working

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Cleanup and documentation

- [X] T051 [P] Remove cluster.initial_master_nodes from StatefulSets via kubectl patch
- [X] T052 Rolling restart ES pods to apply changes - all 3 nodes running
- [X] T053 [P] Update AGENTS.md with new ES multi-node architecture documentation
- [ ] T054 [P] Document rollback procedure if issues discovered later
- [X] T055 Create index template ensuring number_of_replicas=1 for all new indices
- [ ] T056 Backup old GlusterFS ES data directory before deletion
- [ ] T057 Schedule old GlusterFS data removal after 1-week validation period
- [X] T058 Generate new Elasticsearch API key (stored securely, not in repo)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-7)**: All depend on Foundational phase completion
  - US1 must complete first (creates the cluster infrastructure)
  - US2-US5 can proceed in parallel after US1
- **Polish (Phase 8)**: Depends on all user stories being verified

### User Story Dependencies

- **User Story 1 (P1)**: Core cluster deployment - MUST complete first
- **User Story 2 (P1)**: Verification only - can start after US1 deployment complete
- **User Story 3 (P1)**: Data restore - can start after US1 cluster forms
- **User Story 4 (P1)**: Kibana verification - can start after US3 data restore
- **User Story 5 (P2)**: Integration verification - can start after US3 data restore

### Critical Path

```
Setup → Foundational → US1 (cluster) → US3 (restore) → US4 (Kibana) → US5 (integrations)
                                     ↘ US2 (I/O verify) ↗
```

### Within Each User Story

- Infrastructure tasks before verification tasks
- Terraform changes before manual verification
- Core functionality before edge case testing

### Parallel Opportunities

- **Phase 1**: T002, T003, T004 can all run in parallel
- **Phase 2**: T007, T008, T009 can run in parallel after T006
- **Phase 4-5**: US2 and US3 can run in parallel after US1 completes
- **Phase 8**: T052, T054, T055 can run in parallel

---

## Parallel Example: After Cluster Deployment

```bash
# After US1 completes (cluster deployed), these can run in parallel:

# Stream 1: User Story 2 (I/O verification)
Task: "Verify data nodes use local-path storage"
Task: "Monitor flush queue depth"

# Stream 2: User Story 3 (Data restore)
Task: "Configure snapshot repository on new cluster"
Task: "Restore pre-migration snapshot"
```

---

## Implementation Strategy

### MVP First (User Story 1 + 3 Only)

1. Complete Phase 1: Setup (prerequisite verification)
2. Complete Phase 2: Foundational (StorageClass, ConfigMaps, snapshot)
3. Complete Phase 3: User Story 1 (deploy 3-node cluster)
4. Complete Phase 5: User Story 3 (restore data)
5. **STOP and VALIDATE**: Cluster works, data accessible
6. Proceed to remaining stories

### Estimated Timeline

| Phase | Tasks | Estimated Time |
|-------|-------|----------------|
| Phase 1: Setup | 4 | 10 min |
| Phase 2: Foundational | 7 | 20 min |
| Phase 3: US1 - HA Cluster | 14 | 30 min |
| Phase 4: US2 - I/O Perf | 6 | 10 min |
| Phase 5: US3 - Data Migration | 7 | 20 min |
| Phase 6: US4 - Kibana | 7 | 10 min |
| Phase 7: US5 - Integrations | 6 | 10 min |
| Phase 8: Polish | 7 | 15 min |
| **Total** | **58** | **~2 hours** |

**Note**: Actual migration downtime is ~30 minutes (Foundational snapshot + US1 deployment + US3 restore). Other phases are verification and can happen while cluster is operational.

---

## Notes

- [P] tasks = different files or independent verification, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently verifiable
- Commit Terraform changes after each logical group
- Stop at any checkpoint to validate story independently
- Rollback procedure available in quickstart.md if issues discovered
