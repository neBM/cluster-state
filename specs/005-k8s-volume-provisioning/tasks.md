# Tasks: Kubernetes Volume Provisioning

**Input**: Design documents from `/specs/005-k8s-volume-provisioning/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Manual verification via `kubectl` and `terraform plan/apply` as specified in quickstart.md. No automated tests requested.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Infrastructure-as-Code**: `modules-k8s/` for K8s Terraform modules
- **Main config**: `kubernetes.tf` at repository root
- **Documentation**: `AGENTS.md` at repository root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the NFS provisioner module structure

- [x] T001 Create module directory structure at modules-k8s/nfs-provisioner/
- [x] T002 [P] Create versions.tf with Terraform and provider requirements in modules-k8s/nfs-provisioner/versions.tf
- [x] T003 [P] Create variables.tf with module inputs in modules-k8s/nfs-provisioner/variables.tf

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core provisioner infrastructure that MUST be complete before testing

**CRITICAL**: No user story validation can begin until this phase is complete

- [x] T004 Create ServiceAccount for provisioner in modules-k8s/nfs-provisioner/main.tf
- [x] T005 Create ClusterRole with PV/PVC permissions in modules-k8s/nfs-provisioner/main.tf
- [x] T006 Create ClusterRoleBinding linking ServiceAccount to ClusterRole in modules-k8s/nfs-provisioner/main.tf
- [x] T007 Create provisioner Deployment with NFS mount in modules-k8s/nfs-provisioner/main.tf
- [x] T008 Create StorageClass with pathPattern for naming convention in modules-k8s/nfs-provisioner/storage-class.tf
- [x] T009 Add nfs-provisioner module to kubernetes.tf
- [x] T010 Run terraform plan to validate configuration

**Checkpoint**: Provisioner deployed - user story validation can now begin

---

## Phase 3: User Story 1 - Deploy New K8s Service with Storage (Priority: P1)

**Goal**: Deploy a new K8s service with persistent storage without manual SSH intervention

**Independent Test**: Create test PVC and pod, verify directory auto-created and pod can read/write

### Implementation for User Story 1

- [x] T011 [US1] Run terraform apply to deploy nfs-provisioner
- [x] T012 [US1] Verify provisioner pod is running via kubectl get pods
- [x] T013 [US1] Verify StorageClass glusterfs-nfs exists via kubectl get storageclass
- [x] T014 [US1] Create test PVC with volume-name annotation using kubectl apply
- [x] T015 [US1] Verify PVC transitions to Bound state within 30 seconds
- [x] T016 [US1] Verify directory /storage/v/glusterfs_test_data created on node via SSH
- [x] T017 [US1] Create test pod that mounts the PVC
- [x] T018 [US1] Verify pod can write to and read from mounted volume
- [x] T019 [US1] Clean up test resources (pod and PVC)
- [x] T020 [US1] Verify directory retained after PVC deletion (Retain policy)

**Checkpoint**: User Story 1 complete - auto-provisioning works for new services

---

## Phase 4: User Story 2 - Terraform-Managed Volume Lifecycle (Priority: P2)

**Goal**: Volume resources visible in Terraform state with appropriate lifecycle warnings

**Independent Test**: View Terraform state showing PVC resources, verify destroy shows data warning

### Implementation for User Story 2

- [x] T021 [US2] Create example PVC resource in modules-k8s/nfs-provisioner/examples.tf for documentation
- [x] T022 [US2] Run terraform state list and verify provisioner resources visible
- [x] T023 [US2] Run terraform plan -destroy on nfs-provisioner module
- [x] T024 [US2] Verify plan shows PVC and related resources will be destroyed
- [x] T025 [US2] Document lifecycle behavior in quickstart.md (data retained on PVC delete)

**Checkpoint**: User Story 2 complete - Terraform visibility confirmed

---

## Phase 5: User Story 3 - Volume Naming Consistency (Priority: P3)

**Goal**: K8s volumes follow glusterfs_<service>_<type> naming convention

**Independent Test**: Create volumes for test service, verify naming matches pattern and backup scripts would include them

### Implementation for User Story 3

- [x] T026 [US3] Create PVC with annotation volume-name: myapp_config
- [x] T027 [US3] Create PVC with annotation volume-name: myapp_data
- [x] T028 [US3] Verify directories are /storage/v/glusterfs_myapp_config and /storage/v/glusterfs_myapp_data
- [x] T029 [US3] Verify directories appear in ls /storage/v/glusterfs_* glob
- [x] T030 [US3] Verify directories have correct permissions (0777, root:root)
- [x] T031 [US3] Clean up test PVCs

**Checkpoint**: User Story 3 complete - naming convention validated

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and operational readiness

- [x] T032 [P] Update AGENTS.md with PVC usage pattern for new services
- [x] T033 [P] Update AGENTS.md with hostPath vs PVC guidance
- [x] T034 [P] Update AGENTS.md with troubleshooting section for provisioner
- [x] T035 Add Active Technologies entry for NFS Subdir External Provisioner to AGENTS.md
- [x] T036 Verify all existing K8s services still running (no breaking changes - SC-003)
- [x] T037 Run quickstart.md validation steps end-to-end
- [x] T038 Commit all changes with descriptive message

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-5)**: All depend on Foundational phase completion
  - Must be executed sequentially (validation tests require real cluster)
- **Polish (Phase 6)**: Depends on all user stories being validated

### User Story Dependencies

- **User Story 1 (P1)**: Depends on Foundational (T004-T010) - Core functionality
- **User Story 2 (P2)**: Depends on US1 completion - Requires provisioner deployed
- **User Story 3 (P3)**: Depends on US1 completion - Requires provisioner working

### Within Each Phase

- Setup tasks T002-T003 marked [P] can run in parallel
- Foundational tasks are sequential (RBAC → Deployment → StorageClass → Integration)
- User Story tasks are sequential (deploy → verify → test → cleanup)
- Polish tasks T032-T034 marked [P] can run in parallel

### Parallel Opportunities

```text
# Phase 1 - Setup (parallel):
T002 versions.tf    ──┬──> T004 (Foundational)
T003 variables.tf   ──┘

# Phase 6 - Polish (parallel):
T032 AGENTS.md PVC pattern     ──┬──> T035 (sequential - same file)
T033 AGENTS.md hostPath guide  ──┤
T034 AGENTS.md troubleshooting ──┘
```

---

## Parallel Example: Setup Phase

```bash
# Launch setup tasks together:
Task: "Create versions.tf with Terraform and provider requirements in modules-k8s/nfs-provisioner/versions.tf"
Task: "Create variables.tf with module inputs in modules-k8s/nfs-provisioner/variables.tf"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T003)
2. Complete Phase 2: Foundational (T004-T010)
3. Complete Phase 3: User Story 1 (T011-T020)
4. **STOP and VALIDATE**: Provisioner creates directories automatically
5. Can deploy new services immediately after US1

### Incremental Delivery

1. Setup + Foundational → Provisioner deployed
2. User Story 1 → Auto-provisioning works → **MVP READY**
3. User Story 2 → Terraform visibility confirmed
4. User Story 3 → Naming convention validated
5. Polish → Documentation complete → **FEATURE COMPLETE**

### Success Criteria Mapping

| Criterion | Validated By |
|-----------|--------------|
| SC-001: Single terraform apply | T011, T015 |
| SC-002: Creation < 30s | T015 |
| SC-003: No breaking changes | T036 |
| SC-004: Naming convention | T028, T029 |

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- All user story validation requires real cluster - run sequentially
- Manual cleanup (T019, T031) ensures test isolation
- Commit after each phase completion
- quickstart.md contains detailed test commands for all verification steps
