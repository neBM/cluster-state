# Tasks: Nomad to Kubernetes Full Migration

**Input**: Design documents from `/specs/004-nomad-to-k8s-migration/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Not included - this is an IaC migration project with manual verification per service.

**Organization**: Tasks are grouped by migration phase (which map to user stories). Each phase can be completed and verified independently.

## Format: `[ID] [P?] [Phase] Description`

- **[P]**: Can run in parallel (different files/services, no dependencies)
- **[Phase]**: Migration phase this task belongs to (PH1-PH11)
- Include exact file paths in descriptions

## Path Conventions

- **K8s Modules**: `modules-k8s/<service>/`
- **Nomad Modules**: `modules/<service>/` (existing, for reference)
- **External Traefik**: `/mnt/docker/traefik/traefik/dynamic_conf.yml` on Hestia

---

## Phase 0: Cleanup & Preparation

**Purpose**: Delete K8s PoC overseerr, verify prerequisites

- [x] T001 Delete existing K8s overseerr PoC via `terraform destroy -target=module.k8s_overseerr`
- [x] T002 [P] Verify K8s cluster health: `kubectl get nodes`, all nodes Ready
- [x] T003 [P] Verify ClusterSecretStore: `kubectl get clustersecretstores vault-backend`
- [x] T004 [P] Verify TLS secret: `kubectl get secret -n traefik wildcard-brmartin-tls`
- [x] T005 [P] Verify NVIDIA GPU available: `kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'` (Note: GPU not available yet - need device plugin for Phase 3)

**Checkpoint**: Prerequisites verified, ready to begin migration

---

## Phase 1: Stateless Services - searxng, nginx-sites (Priority: P1)

**Goal**: Migrate simplest services to build confidence and validate patterns

**Independent Test**: `curl https://searx.brmartin.co.uk` and `curl https://brmartin.co.uk` return expected content

### searxng

- [x] T006 [PH1] Stop Nomad job: `nomad job stop searxng`
- [x] T007 [P] [PH1] Create modules-k8s/searxng/versions.tf with kubernetes and kubectl providers
- [x] T008 [P] [PH1] Create modules-k8s/searxng/variables.tf with namespace, image_tag, hostname
- [x] T009 [P] [PH1] Create modules-k8s/searxng/outputs.tf with service_name, hostname, namespace
- [x] T010 [PH1] Create modules-k8s/searxng/main.tf with Deployment, Service, Ingress (Pattern A) - Note: Added node_selector for hestia due to GlusterFS NFS mount location
- [x] T011 [PH1] Add module.k8s_searxng to kubernetes.tf
- [x] T012 [PH1] Deploy: `terraform apply -target=module.k8s_searxng`
- [x] T013 [PH1] Update external Traefik dynamic_conf.yml with k8s-searxng router (oauth-auth middleware)
- [x] T014 [PH1] Verify: `curl -sI https://searx.brmartin.co.uk` returns 200 or OAuth redirect (returns 403 - OAuth middleware working)

### nginx-sites

- [x] T015 [PH1] Stop Nomad job: `nomad job stop nginx-sites`
- [x] T016 [P] [PH1] Create modules-k8s/nginx-sites/versions.tf with kubernetes and kubectl providers
- [x] T017 [P] [PH1] Create modules-k8s/nginx-sites/variables.tf with namespace, image_tag, hostnames list
- [x] T018 [P] [PH1] Create modules-k8s/nginx-sites/outputs.tf with service_name, hostnames, namespace
- [x] T019 [PH1] Create modules-k8s/nginx-sites/main.tf with Deployment, Service, multi-host Ingress
- [x] T020 [PH1] Add module.k8s_nginx_sites to kubernetes.tf
- [x] T021 [PH1] Deploy: `terraform apply -target=module.k8s_nginx_sites`
- [x] T022 [PH1] Update external Traefik with routers for brmartin.co.uk, martinilink.co.uk
- [x] T023 [PH1] Verify: `curl https://brmartin.co.uk` and `curl https://martinilink.co.uk`

**Checkpoint**: Phase 1 complete - stateless services migrated, patterns validated

---

## Phase 2: Litestream Services - vaultwarden, overseerr (Priority: P1)

**Goal**: Migrate vaultwarden (external PostgreSQL) and overseerr (SQLite + litestream)

**Independent Test**: Log into Vaultwarden at `bw.brmartin.co.uk`, verify passwords exist; access Overseerr at `overseerr.brmartin.co.uk`

### vaultwarden

Note: Vaultwarden uses external PostgreSQL on martinibar.lan, NOT SQLite/litestream. Pattern A (stateless with persistent config).

- [x] T024 [PH2] Stop Nomad job: `nomad job stop vaultwarden`
- [x] T025 [P] [PH2] Create modules-k8s/vaultwarden/versions.tf
- [x] T026 [P] [PH2] Create modules-k8s/vaultwarden/variables.tf with namespace, image_tag, hostname
- [x] T027 [P] [PH2] Create modules-k8s/vaultwarden/outputs.tf
- [x] T028 [PH2] Create modules-k8s/vaultwarden/main.tf with Deployment, ExternalSecret for DB/SMTP/Admin credentials
- [x] T029 [PH2] Add module.k8s_vaultwarden to kubernetes.tf
- [x] T030 [PH2] Deploy: `terraform apply -target=module.k8s_vaultwarden`
- [x] T031 [PH2] Update external Traefik with k8s-vaultwarden router
- [x] T032 [PH2] Verify: Access `bw.brmartin.co.uk`, confirm web UI loads

### overseerr (production replacement)

Note: Reused existing PoC module from previous session, updated for production (hostname, Vault path, MinIO endpoint).

- [x] T034 [PH2] Stop Nomad job: `nomad job stop overseerr`
- [x] T035 [P] [PH2] Reused existing modules-k8s/overseerr/ from PoC
- [x] T036 [P] [PH2] Updated modules-k8s/overseerr/variables.tf with production defaults
- [x] T037 [P] [PH2] Updated modules-k8s/overseerr/outputs.tf
- [x] T038 [PH2] Updated modules-k8s/overseerr/secrets.tf to use nomad/default/overseerr Vault path
- [x] T039 [PH2] Updated modules-k8s/overseerr/main.tf with hostPath for config, production hostname
- [x] T040 [PH2] Add module.k8s_overseerr to kubernetes.tf
- [x] T041 [PH2] Deploy: `terraform apply -target=module.k8s_overseerr`
- [x] T042 [PH2] Update external Traefik with k8s-overseerr router (overseerr.brmartin.co.uk)
- [x] T043 [PH2] Verify: Database restored from litestream, redirects to /login (data intact)

**Checkpoint**: Phase 2 complete - litestream pattern proven with critical services

---

## Phase 3: AI Stack - open-webui, ollama (Priority: P1)

**Goal**: Migrate AI services including GPU workload

**Independent Test**: Access `chat.brmartin.co.uk`, send a message, receive AI response

### ollama (GPU)

- [x] T044 [PH3] Stop Nomad job: `nomad job stop ollama`
- [x] T045 [P] [PH3] Create modules-k8s/ollama/versions.tf
- [x] T046 [P] [PH3] Create modules-k8s/ollama/variables.tf with model_storage path
- [x] T047 [P] [PH3] Create modules-k8s/ollama/outputs.tf
- [x] T048 [PH3] Create modules-k8s/ollama/main.tf with Deployment + GPU (Pattern D, nodeSelector for hestia)
- [x] T049 [PH3] Add module.k8s_ollama to kubernetes.tf
- [x] T050 [PH3] Deploy: `terraform apply -target=module.k8s_ollama`
- [x] T051 [PH3] Verify: `kubectl exec` into a debug pod, curl ollama service
- [x] T051a [PH3] Add NodePort service (31434) so Nomad services can reach K8s ollama
- [x] T051b [PH3] Pull llama3.2:3b model for testing

### open-webui (Hybrid - kept on Nomad, connected to K8s ollama)

Note: open-webui depends on valkey (Redis) and postgres (pgvector), both running on Nomad with Consul Connect.
K8s pods cannot resolve Consul DNS (*.virtual.consul). Decision: Keep open-webui on Nomad, update to use K8s ollama.

- [x] T052 [PH3] Update Nomad open-webui job to use K8s ollama at `http://192.168.1.5:31434`
- [x] T053 [PH3] Deploy updated Nomad job: `nomad job run modules/open-webui/jobspec.nomad.hcl`
- [x] T054 [PH3] Verify: open-webui can reach K8s ollama (curl from alloc works)
- [x] T055 [PH3] Verify: Access `chat.brmartin.co.uk`, returns 200

**Checkpoint**: Phase 3 complete - ollama migrated to K8s with GPU, open-webui on Nomad connects to K8s ollama via NodePort

---

## Phase 4: MinIO - Critical Infrastructure (Priority: P1)

**Goal**: Migrate MinIO (affects all litestream services)

**Independent Test**: `mc ls minio/` works, litestream backups continue for migrated services

**CRITICAL**: This migration affects all services using litestream. Verify backups work after migration.

- [x] T062 [PH4] Stop Nomad job: `nomad job stop minio`
- [x] T063 [P] [PH4] Create modules-k8s/minio/versions.tf
- [x] T064 [P] [PH4] Create modules-k8s/minio/variables.tf with data_path, root credentials
- [x] T065 [P] [PH4] Create modules-k8s/minio/outputs.tf with s3_endpoint, console_url
- [x] T066 [PH4] Create modules-k8s/minio/secrets.tf with ExternalSecret for root credentials
- [x] T067 [PH4] Create modules-k8s/minio/main.tf with Deployment, dual Service (S3 NodePort + console ClusterIP), Ingress
- [x] T068 [PH4] Add module.k8s_minio to kubernetes.tf
- [x] T069 [PH4] Deploy: `terraform apply -target=module.k8s_minio`
- [x] T070 [PH4] Update external Traefik with k8s-minio router
- [x] T071 [PH4] Verify MinIO: `mc ls minio/` shows buckets
- [x] T072 [PH4] Update minio_endpoint in overseerr to `http://minio-api.default.svc.cluster.local:9000`
- [x] T073 [PH4] Redeploy litestream services: overseerr restarted with new endpoint
- [x] T074 [PH4] Verify litestream: Pod logs show successful replication to new MinIO endpoint

**Checkpoint**: Phase 4 complete - MinIO migrated, litestream verified working

---

## Phase 5: Keycloak - SSO Provider (Priority: P2)

**Goal**: Migrate SSO provider (other services may depend on it)

**Independent Test**: Access `sso.brmartin.co.uk`, complete OAuth login flow

- [x] T075 [PH5] Stop Nomad job: `nomad job stop keycloak`
- [x] T076 [P] [PH5] Create modules-k8s/keycloak/versions.tf
- [x] T077 [P] [PH5] Create modules-k8s/keycloak/variables.tf with db_host, db_port, hostname
- [x] T078 [P] [PH5] Create modules-k8s/keycloak/outputs.tf
- [x] T079 [PH5] Create modules-k8s/keycloak/secrets.tf with ExternalSecret for DB password
- [x] T080 [PH5] Create modules-k8s/keycloak/main.tf with Deployment, Service, Ingress
- [x] T081 [PH5] Add module.k8s_keycloak to kubernetes.tf
- [x] T082 [PH5] Deploy: `terraform apply -target=module.k8s_keycloak`
- [x] T083 [PH5] Update external Traefik with k8s-keycloak router
- [x] T084 [PH5] Verify: Access `sso.brmartin.co.uk` returns 302 redirect to /admin/, OAuth middleware (403) working

Note: Created Vault secret `nomad/default/keycloak` from existing Nomad variable. Health probes use management port 9000 (not 8080).

**Checkpoint**: Phase 5 complete - SSO provider migrated

---

## Phase 6: AppFlowy - Multi-container (Priority: P2)

**Goal**: Migrate AppFlowy document service

**Independent Test**: Access `docs.brmartin.co.uk`, open/edit a document

- [x] T085 [PH6] Stop Nomad job: `nomad job stop appflowy`
- [x] T086 [P] [PH6] Create modules-k8s/appflowy/versions.tf
- [x] T087 [P] [PH6] Create modules-k8s/appflowy/variables.tf with storage paths
- [x] T088 [P] [PH6] Create modules-k8s/appflowy/outputs.tf
- [x] T089 [PH6] Create modules-k8s/appflowy/secrets.tf with ExternalSecret for gotrue/appflowy credentials
- [x] T090 [PH6] Create modules-k8s/appflowy/main.tf with 7 separate Deployments (gotrue, cloud, worker, admin-frontend, web, postgres, redis)
- [x] T091 [PH6] Add module.k8s_appflowy to kubernetes.tf
- [x] T092 [PH6] Deploy: `terraform apply -target=module.k8s_appflowy`
- [x] T093 [PH6] Update external Traefik with k8s-appflowy router
- [x] T094 [PH6] Verify: Access `docs.brmartin.co.uk`, web frontend loads, API health returns 200

Note: AppFlowy uses 7 separate Deployments (not a StatefulSet) with IngressRoute CRD for path-based routing and middleware support. K8s service DNS replaces Consul DNS for inter-service communication. PostgreSQL uses hostPath on Hestia (/storage/v/glusterfs_appflowy_postgres). MinIO and Keycloak endpoints updated to use K8s services.

**Checkpoint**: Phase 6 complete - multi-container pattern validated

---

## Phase 7: ELK - Observability (Priority: P2)

**Goal**: Migrate Elasticsearch + Kibana for logging

**Independent Test**: Access `kibana.brmartin.co.uk`, view logs; API at `es.brmartin.co.uk` responds

- [ ] T095 [PH7] Stop Nomad job: `nomad job stop elk`
- [ ] T096 [P] [PH7] Create modules-k8s/elk/versions.tf
- [ ] T097 [P] [PH7] Create modules-k8s/elk/variables.tf with storage paths, heap settings
- [ ] T098 [P] [PH7] Create modules-k8s/elk/outputs.tf
- [ ] T099 [PH7] Create modules-k8s/elk/secrets.tf with ExternalSecret for elastic credentials
- [ ] T100 [PH7] Create modules-k8s/elk/main.tf with Elasticsearch StatefulSet, Kibana Deployment, Services, Ingresses
- [ ] T101 [PH7] Add module.k8s_elk to kubernetes.tf
- [ ] T102 [PH7] Deploy: `terraform apply -target=module.k8s_elk`
- [ ] T103 [PH7] Update external Traefik with k8s-elasticsearch and k8s-kibana routers
- [ ] T104 [PH7] Verify: `curl https://es.brmartin.co.uk/_cluster/health`, access Kibana

**Checkpoint**: Phase 7 complete - observability migrated

---

## Phase 8: Nextcloud - File Storage (Priority: P2)

**Goal**: Migrate Nextcloud file storage with Collabora

**Independent Test**: Access `cloud.brmartin.co.uk`, browse files, edit a document with Collabora

- [ ] T105 [PH8] Stop Nomad job: `nomad job stop nextcloud`
- [ ] T106 [P] [PH8] Create modules-k8s/nextcloud/versions.tf
- [ ] T107 [P] [PH8] Create modules-k8s/nextcloud/variables.tf with storage paths, collabora settings
- [ ] T108 [P] [PH8] Create modules-k8s/nextcloud/outputs.tf
- [ ] T109 [PH8] Create modules-k8s/nextcloud/secrets.tf with ExternalSecret
- [ ] T110 [PH8] Create modules-k8s/nextcloud/main.tf with Nextcloud + Collabora pods, Services, Ingresses
- [ ] T111 [PH8] Add module.k8s_nextcloud to kubernetes.tf
- [ ] T112 [PH8] Deploy: `terraform apply -target=module.k8s_nextcloud`
- [ ] T113 [PH8] Update external Traefik with k8s-nextcloud router
- [ ] T114 [PH8] Verify: Access `cloud.brmartin.co.uk`, browse files, test Collabora editing

**Checkpoint**: Phase 8 complete - file storage migrated

---

## Phase 9: Matrix - Communication (Priority: P2)

**Goal**: Migrate Matrix homeserver with Element/Cinny frontends

**Independent Test**: Access `element.brmartin.co.uk`, view room history, send a message

- [ ] T115 [PH9] Stop Nomad job: `nomad job stop matrix`
- [ ] T116 [P] [PH9] Create modules-k8s/matrix/versions.tf
- [ ] T117 [P] [PH9] Create modules-k8s/matrix/variables.tf with storage paths, frontend configs
- [ ] T118 [P] [PH9] Create modules-k8s/matrix/outputs.tf
- [ ] T119 [PH9] Create modules-k8s/matrix/secrets.tf with ExternalSecret
- [ ] T120 [PH9] Create modules-k8s/matrix/main.tf with Synapse StatefulSet, Element/Cinny Deployments, Services, Ingresses
- [ ] T121 [PH9] Add module.k8s_matrix to kubernetes.tf
- [ ] T122 [PH9] Deploy: `terraform apply -target=module.k8s_matrix`
- [ ] T123 [PH9] Update external Traefik with k8s-matrix, k8s-element, k8s-cinny routers
- [ ] T124 [PH9] Verify: Access Element, view message history, send a message

**Checkpoint**: Phase 9 complete - communication services migrated

---

## Phase 10: GitLab - Source Control (Priority: P2)

**Goal**: Migrate GitLab (most complex service) with runner

**Independent Test**: Access `git.brmartin.co.uk`, clone a repo, push a commit, trigger CI pipeline

### gitlab

- [ ] T125 [PH10] Stop Nomad job: `nomad job stop gitlab`
- [ ] T126 [P] [PH10] Create modules-k8s/gitlab/versions.tf
- [ ] T127 [P] [PH10] Create modules-k8s/gitlab/variables.tf with storage paths, registry config
- [ ] T128 [P] [PH10] Create modules-k8s/gitlab/outputs.tf
- [ ] T129 [PH10] Create modules-k8s/gitlab/secrets.tf with ExternalSecret for GitLab secrets
- [ ] T130 [PH10] Create modules-k8s/gitlab/main.tf with GitLab StatefulSet (rails, gitaly, registry), Services, Ingresses
- [ ] T131 [PH10] Add module.k8s_gitlab to kubernetes.tf
- [ ] T132 [PH10] Deploy: `terraform apply -target=module.k8s_gitlab`
- [ ] T133 [PH10] Update external Traefik with k8s-gitlab, k8s-registry routers
- [ ] T134 [PH10] Verify: Access `git.brmartin.co.uk`, clone repo, view issues

### gitlab-runner

- [ ] T135 [PH10] Stop Nomad job: `nomad job stop gitlab-runner`
- [ ] T136 [P] [PH10] Create modules-k8s/gitlab-runner/versions.tf
- [ ] T137 [P] [PH10] Create modules-k8s/gitlab-runner/variables.tf with gitlab URL, runner token
- [ ] T138 [P] [PH10] Create modules-k8s/gitlab-runner/outputs.tf
- [ ] T139 [PH10] Create modules-k8s/gitlab-runner/secrets.tf with ExternalSecret for runner token
- [ ] T140 [PH10] Create modules-k8s/gitlab-runner/main.tf with Deployment (docker-in-docker pattern)
- [ ] T141 [PH10] Add module.k8s_gitlab_runner to kubernetes.tf
- [ ] T142 [PH10] Deploy: `terraform apply -target=module.k8s_gitlab_runner`
- [ ] T143 [PH10] Verify: Push a commit, confirm CI pipeline runs

**Checkpoint**: Phase 10 complete - GitLab and CI migrated (most complex service done)

---

## Phase 11: Periodic Jobs - renovate, restic-backup (Priority: P3)

**Goal**: Migrate scheduled jobs as K8s CronJobs

**Independent Test**: Wait for next scheduled run, verify job completes successfully

### renovate

- [ ] T144 [PH11] Stop Nomad job: `nomad job stop renovate` (if exists as periodic)
- [ ] T145 [P] [PH11] Create modules-k8s/renovate/versions.tf
- [ ] T146 [P] [PH11] Create modules-k8s/renovate/variables.tf with schedule, gitlab token
- [ ] T147 [P] [PH11] Create modules-k8s/renovate/outputs.tf
- [ ] T148 [PH11] Create modules-k8s/renovate/secrets.tf with ExternalSecret for tokens
- [ ] T149 [PH11] Create modules-k8s/renovate/main.tf with CronJob (Pattern E)
- [ ] T150 [PH11] Add module.k8s_renovate to kubernetes.tf
- [ ] T151 [PH11] Deploy: `terraform apply -target=module.k8s_renovate`
- [ ] T152 [PH11] Verify: `kubectl get cronjobs`, wait for next run, check job logs

### restic-backup

- [ ] T153 [PH11] Stop Nomad job: `nomad job stop restic-backup`
- [ ] T154 [P] [PH11] Create modules-k8s/restic-backup/versions.tf
- [ ] T155 [P] [PH11] Create modules-k8s/restic-backup/variables.tf with schedule, backup paths
- [ ] T156 [P] [PH11] Create modules-k8s/restic-backup/outputs.tf
- [ ] T157 [PH11] Create modules-k8s/restic-backup/secrets.tf with ExternalSecret for restic password
- [ ] T158 [PH11] Create modules-k8s/restic-backup/main.tf with CronJob (Pattern E, hostPath access)
- [ ] T159 [PH11] Add module.k8s_restic_backup to kubernetes.tf
- [ ] T160 [PH11] Deploy: `terraform apply -target=module.k8s_restic_backup`
- [ ] T161 [PH11] Verify: Wait for next scheduled run, check backup completed

**Checkpoint**: Phase 11 complete - all periodic jobs migrated

---

## Phase 12: Polish & Verification

**Purpose**: Final cleanup and documentation

- [ ] T162 [P] Verify all K8s pods healthy: `kubectl get pods -A | grep -v Running`
- [ ] T163 [P] Verify Nomad only has expected jobs: `nomad job status` shows only media-centre, CSI plugins
- [ ] T164 [P] Verify Hubble shows service mesh traffic between services
- [ ] T165 Update AGENTS.md with K8s-specific commands and updated service inventory
- [ ] T166 Update constitution.md if any principles need adjustment for K8s
- [ ] T167 Monitor all services for 24 hours, check health continuously
- [ ] T168 Document any service-specific quirks discovered during migration

**Checkpoint**: Migration complete - all services on K8s, Nomad decommissioned (except excluded)

---

## Dependencies & Execution Order

### Phase Dependencies

```
Phase 0 (Cleanup) ─────────────────────────────────────────────┐
                                                               │
Phase 1 (Stateless) ───────────────────────────────────────────┼─→ Phase 12 (Polish)
                                                               │
Phase 2 (Litestream) ──┬───────────────────────────────────────┤
                       │                                       │
Phase 3 (AI Stack) ────┤                                       │
                       │                                       │
Phase 4 (MinIO) ───────┴─→ Updates minio_endpoint in 2, 3 ────┤
                                                               │
Phase 5 (Keycloak) ────────────────────────────────────────────┤
                                                               │
Phase 6 (AppFlowy) ────────────────────────────────────────────┤
                                                               │
Phase 7 (ELK) ─────────────────────────────────────────────────┤
                                                               │
Phase 8 (Nextcloud) ───────────────────────────────────────────┤
                                                               │
Phase 9 (Matrix) ──────────────────────────────────────────────┤
                                                               │
Phase 10 (GitLab) ─────────────────────────────────────────────┤
                                                               │
Phase 11 (CronJobs) ───────────────────────────────────────────┘
```

### Critical Dependencies

1. **Phase 0** must complete before any migration (delete PoC overseerr)
2. **Phase 4 (MinIO)** must complete before updating minio_endpoint in Phases 2-3
3. **Phase 10 (GitLab)** should be last major service (most complex)
4. **Phase 12 (Polish)** only after all services verified

### Within Each Phase

- Stop Nomad job FIRST (release resources, prevent storage conflicts)
- Create all module files (can be parallel for versions.tf, variables.tf, outputs.tf)
- Deploy via Terraform
- Update external Traefik
- Verify service works before proceeding

### Parallel Opportunities

- Within a phase: versions.tf, variables.tf, outputs.tf can be created in parallel
- Different phases can run in parallel EXCEPT:
  - Phase 4 (MinIO) affects Phases 2, 3 (litestream endpoint)
  - All phases wait for Phase 0 to complete
- Multiple services within same phase run sequentially (one-at-a-time strategy)

---

## Parallel Example: Phase 2 Module Creation

```bash
# After stopping Nomad job, create boilerplate files in parallel:
Task: "Create modules-k8s/vaultwarden/versions.tf"
Task: "Create modules-k8s/vaultwarden/variables.tf"
Task: "Create modules-k8s/vaultwarden/outputs.tf"

# Then sequentially:
Task: "Create modules-k8s/vaultwarden/secrets.tf"  # May reference variables
Task: "Create modules-k8s/vaultwarden/main.tf"     # References all above
```

---

## Implementation Strategy

### MVP First (Phases 0-4)

1. **Phase 0**: Cleanup PoC, verify prerequisites
2. **Phase 1**: Migrate searxng, nginx-sites (validate stateless pattern)
3. **Phase 2**: Migrate vaultwarden, overseerr (validate litestream pattern)
4. **Phase 3**: Migrate ollama, open-webui (validate GPU pattern)
5. **Phase 4**: Migrate MinIO (critical infrastructure)

At this point, 7 services are migrated including critical passwords (vaultwarden) and AI (open-webui).

### Incremental Delivery

After MVP, migrate in priority order:
- Phase 5-9: Supporting services (keycloak, appflowy, elk, nextcloud, matrix)
- Phase 10: GitLab (most complex, save for last)
- Phase 11: CronJobs (low risk)

### Rollback Plan

If any service fails after migration:
1. Delete K8s workload: `kubectl delete deployment/<service>`
2. Restart Nomad job: `nomad job run modules/<service>/jobspec.nomad.hcl`
3. Remove K8s route from external Traefik
4. Investigate and fix before retrying

---

## Notes

- **One service at a time**: Due to resource constraints, never run both Nomad and K8s versions simultaneously
- **Stop Nomad first**: Always stop the Nomad job before deploying K8s equivalent
- **Verify before proceeding**: Each service must be verified working before moving to the next
- **MinIO is critical**: Phase 4 affects all litestream services - extra verification required
- **GitLab is complex**: Phase 10 has multiple components - expect longer migration time
- Commit after each phase or logical group of tasks
