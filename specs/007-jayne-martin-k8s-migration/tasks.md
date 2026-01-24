# Tasks: Jayne Martin Counselling K8s Migration

**Input**: Design documents from `/specs/007-jayne-martin-k8s-migration/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, quickstart.md

**Tests**: No automated tests requested - verification is via manual HTTP checks and terraform plan validation.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Terraform modules**: `modules-k8s/jayne-martin-counselling/`
- **Root config**: `kubernetes.tf`, `main.tf`
- **External config**: `/mnt/docker/traefik/traefik/dynamic_conf.yml` (on Hestia)
- **Documentation**: `AGENTS.md`

---

## Phase 1: Setup (Module Creation)

**Purpose**: Create the K8s module directory and file structure

- [X] T001 Create module directory at modules-k8s/jayne-martin-counselling/
- [X] T002 [P] Create versions.tf with provider requirements in modules-k8s/jayne-martin-counselling/versions.tf
- [X] T003 [P] Create variables.tf with namespace, image_tag, vpa_mode in modules-k8s/jayne-martin-counselling/variables.tf

---

## Phase 2: Foundational (K8s Module Implementation)

**Purpose**: Implement the complete K8s module following the whoami pattern - MUST complete before deployment

**⚠️ CRITICAL**: No deployment or traffic cutover can occur until this phase is complete

- [X] T004 Create main.tf with locals block (app_name, labels) in modules-k8s/jayne-martin-counselling/main.tf
- [X] T005 Add kubernetes_deployment resource with container, probes, affinity in modules-k8s/jayne-martin-counselling/main.tf
- [X] T006 Add kubernetes_service resource (ClusterIP, port 80) in modules-k8s/jayne-martin-counselling/main.tf
- [X] T007 Add kubernetes_ingress_v1 resource for www.jaynemartincounselling.co.uk in modules-k8s/jayne-martin-counselling/main.tf
- [X] T008 Add kubectl_manifest for VPA resource in modules-k8s/jayne-martin-counselling/main.tf
- [X] T009 Add module definition to kubernetes.tf

**Checkpoint**: K8s module ready for deployment - run `terraform plan` to validate

---

## Phase 3: User Story 1 - Website Availability on Kubernetes (Priority: P1) 🎯 MVP

**Goal**: Deploy the website to K8s and cut over external traffic with zero downtime

**Independent Test**: Access https://www.jaynemartincounselling.co.uk and verify content loads correctly

### Implementation for User Story 1

- [X] T010 [US1] Run terraform plan targeting k8s_jayne_martin_counselling module
- [X] T011 [US1] Run terraform apply to deploy K8s resources
- [X] T012 [US1] Verify pod is running and healthy via kubectl get pods -l app=jayne-martin-counselling
- [X] T013 [US1] Test internal connectivity via kubectl exec to verify nginx serves content
- [X] T014 [US1] Add k8s-jmc router to /mnt/docker/traefik/traefik/dynamic_conf.yml on Hestia (192.168.1.5)
- [X] T015 [US1] Verify external access via curl -I https://www.jaynemartincounselling.co.uk
- [X] T016 [US1] Monitor health checks for 5 minutes to confirm stability

**Checkpoint**: Website served from K8s, externally accessible - User Story 1 complete

---

## Phase 4: User Story 2 - Nomad Service Decommissioning (Priority: P2)

**Goal**: Remove the Nomad job and Terraform module after K8s is validated

**Independent Test**: Verify website remains accessible after Nomad job is stopped, confirm no Nomad jobs remain

**Dependency**: User Story 1 must be complete and verified

### Implementation for User Story 2

- [X] T017 [US2] Remove jayne_martin_counselling module block from main.tf
- [X] T018 [US2] Run terraform plan to confirm Nomad job will be destroyed
- [X] T019 [US2] Run terraform apply to stop and remove Nomad job
- [X] T020 [US2] Verify website still accessible via https://www.jaynemartincounselling.co.uk
- [X] T021 [US2] Verify no Nomad jobs remain via nomad job status
- [X] T022 [US2] Delete modules/jayne-martin-counselling/ directory (legacy Nomad jobspec)

**Checkpoint**: Nomad job removed, website still functional via K8s - User Story 2 complete

---

## Phase 5: User Story 3 - Nomad Cluster Analysis and Removal (Priority: P3)

**Goal**: Verify Nomad is unused across all nodes and uninstall it, keeping Consul and Vault

**Independent Test**: Verify no Nomad processes running on any node, confirm K8s/Consul/Vault remain functional

**Dependency**: User Story 2 must be complete

### Implementation for User Story 3

- [X] T023 [US3] Analyze Nomad usage on Hestia (192.168.1.5) - check nomad job status and running processes
- [X] T024 [P] [US3] Analyze Nomad usage on Heracles (192.168.1.6) - check running processes
- [X] T025 [P] [US3] Analyze Nomad usage on Nyx (192.168.1.7) - check running processes
- [X] T026 [US3] Stop and disable Nomad service on Hestia via systemctl stop nomad && systemctl disable nomad
- [X] T027 [P] [US3] Stop and disable Nomad service on Heracles via systemctl stop nomad && systemctl disable nomad
- [X] T028 [P] [US3] Stop and disable Nomad service on Nyx via systemctl stop nomad && systemctl disable nomad
- [X] T029 [US3] Verify Consul remains healthy on all nodes via consul members
- [X] T030 [US3] Verify Vault remains healthy via vault status
- [X] T031 [US3] Verify K8s remains healthy via kubectl get nodes

**Checkpoint**: Nomad removed from all nodes, other services unaffected - User Story 3 complete

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation updates and cleanup

- [X] T032 [P] Update AGENTS.md to remove Nomad references and commands
- [X] T033 [P] Update AGENTS.md "Remaining on Nomad" section (should be empty)
- [X] T034 [P] Update AGENTS.md "Migrated Services" table to add jayne-martin-counselling
- [X] T035 Remove Nomad provider from external Traefik config (optional) at /mnt/docker/traefik/traefik/traefik.yml on Hestia - N/A, no Nomad provider configured
- [X] T036 Remove modules/nomad-job/ directory if no longer used
- [X] T037 Run quickstart.md validation to confirm all steps work

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational - can start after T009
- **User Story 2 (Phase 4)**: Depends on User Story 1 completion (website must be verified on K8s)
- **User Story 3 (Phase 5)**: Depends on User Story 2 completion (no Nomad jobs)
- **Polish (Phase 6)**: Depends on User Story 3 completion

### User Story Dependencies

- **User Story 1 (P1)**: Standalone - deploy and verify K8s
- **User Story 2 (P2)**: Requires US1 complete - can't remove Nomad job until K8s verified
- **User Story 3 (P3)**: Requires US2 complete - can't remove Nomad until no jobs remain

### Within Each Phase

- T002 and T003 can run in parallel (different files)
- T024 and T025 can run in parallel (different nodes)
- T027 and T028 can run in parallel (different nodes)
- T032, T033, T034 can run in parallel (different sections of same file)

### Parallel Opportunities

Within Phase 1:
- T002 [P] and T003 [P] can run in parallel

Within Phase 5:
- T024 [P] and T025 [P] can run in parallel (analysis on different nodes)
- T027 [P] and T028 [P] can run in parallel (Nomad removal on different nodes)

Within Phase 6:
- T032 [P], T033 [P], T034 [P] can run in parallel (different AGENTS.md sections)

---

## Parallel Example: Phase 1

```bash
# Launch setup tasks in parallel:
Task: "Create versions.tf with provider requirements in modules-k8s/jayne-martin-counselling/versions.tf"
Task: "Create variables.tf with namespace, image_tag, vpa_mode in modules-k8s/jayne-martin-counselling/variables.tf"
```

## Parallel Example: Phase 5

```bash
# Launch node analysis in parallel:
Task: "Analyze Nomad usage on Heracles (192.168.1.6)"
Task: "Analyze Nomad usage on Nyx (192.168.1.7)"

# Then launch Nomad removal in parallel:
Task: "Stop and disable Nomad service on Heracles"
Task: "Stop and disable Nomad service on Nyx"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T003)
2. Complete Phase 2: Foundational (T004-T009)
3. Complete Phase 3: User Story 1 (T010-T016)
4. **STOP and VALIDATE**: Website accessible at https://www.jaynemartincounselling.co.uk
5. Migration functionally complete - remaining stories are cleanup

### Incremental Delivery

1. Setup + Foundational → K8s module ready
2. User Story 1 → Website on K8s with zero downtime (MVP!)
3. User Story 2 → Nomad job removed, cleanup complete
4. User Story 3 → Nomad fully removed from cluster
5. Polish → Documentation updated

### Rollback Points

- **Before T014**: Revert Terraform, no external impact
- **After T014, before T019**: Remove k8s-jmc from Traefik config, traffic returns to Nomad
- **After T019**: No rollback to Nomad (job destroyed), K8s is only option

---

## Notes

- [P] tasks = different files/nodes, no dependencies
- [Story] label maps task to specific user story for traceability
- This is an infrastructure migration - no automated tests, validation is manual
- Zero downtime achieved by parallel deployment before traffic cutover
- Consul and Vault remain in place after Nomad removal
- External Traefik config must be edited manually on Hestia (not in Terraform)
