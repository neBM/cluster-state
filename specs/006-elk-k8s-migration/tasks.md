# Tasks: ELK Stack Migration to Kubernetes Single-Node

**Input**: Design documents from `/specs/006-elk-k8s-migration/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Manual verification via ES API, Kibana UI, terraform plan (no automated tests)

**Organization**: Tasks organized by user story to enable independent verification at each milestone.

**Special Considerations**:
- Data migration operations (rsync ~23GB) run asynchronously via nohup/background tasks
- Long-running operations monitored via polling rather than synchronous blocking
- Shard relocation (15-45 min) monitored asynchronously

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Terraform modules**: `modules-k8s/elk/` (new K8s module)
- **Existing Nomad module**: `modules/elk/` (to be removed after migration)
- **Specs**: `specs/006-elk-k8s-migration/`
- **External Traefik config**: `/mnt/docker/traefik/traefik/dynamic_conf.yml` on Hestia (192.168.1.5)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare secrets and K8s prerequisites before any migration work

- [ ] T001 Load environment variables and verify ES API connectivity with `set -a && source .env && set +a`
- [ ] T002 Record baseline document count from ES API for migration verification (save to specs/006-elk-k8s-migration/baseline.txt)
- [ ] T003 [P] Verify cluster health is GREEN via ES API `/_cluster/health`
- [ ] T004 [P] Verify all 3 ES nodes present via ES API `/_cat/nodes`
- [ ] T005 [P] Check disk space on Hestia via ES API `/_cat/allocation` (need >50GB)
- [ ] T006 [P] Check GlusterFS space via SSH to 192.168.1.5 `df -h /storage/v/` (need >30GB)
- [ ] T007 Migrate Kibana secrets from Nomad vars to Vault at `secret/k8s/elk/kibana` using `nomad var get` and `vault kv put`

**Checkpoint**: Prerequisites verified, baseline recorded, Vault secrets ready

---

## Phase 2: Foundational (K8s Module and Secrets)

**Purpose**: Create K8s Terraform module and manual secrets before migration

**Note**: K8s module created now but NOT applied until after data migration (Phase 4/US2)

- [ ] T008 Create directory structure for K8s ELK module at modules-k8s/elk/
- [ ] T009 [P] Create modules-k8s/elk/versions.tf with required provider versions
- [ ] T010 [P] Create modules-k8s/elk/variables.tf with all module variables per data-model.md
- [ ] T011 Create modules-k8s/elk/main.tf with Elasticsearch StatefulSet, Services, ConfigMap per data-model.md
- [ ] T012 Add Kibana Deployment, Service, ConfigMap to modules-k8s/elk/main.tf
- [ ] T013 Create modules-k8s/elk/secrets.tf with ExternalSecrets for kibana-credentials and kibana-encryption-keys
- [ ] T014 Add Traefik IngressRoute for es.brmartin.co.uk with ServersTransport to modules-k8s/elk/main.tf
- [ ] T015 Add Traefik IngressRoute for kibana.brmartin.co.uk to modules-k8s/elk/main.tf
- [ ] T016 Add module declaration for k8s_elk in kubernetes.tf at repository root
- [ ] T017 Run `terraform plan -target='module.k8s_elk'` to validate module syntax (do NOT apply yet)
- [ ] T018 Create K8s secret elasticsearch-certs from /mnt/docker/elastic-hestia/config/certs/ via kubectl
- [ ] T019 [P] Create K8s secret kibana-certs from /mnt/docker/elastic/kibana/config/elasticsearch-ca.pem via kubectl
- [ ] T020 Create GlusterFS directory /storage/v/glusterfs_elasticsearch_data with chown 1000:1000 via SSH
- [ ] T021 Prepare external Traefik routes for ES and Kibana in /mnt/docker/traefik/traefik/dynamic_conf.yml (add k8s-es and k8s-kibana routers pointing to to-k8s-traefik, but comment out until migration complete)

**Checkpoint**: K8s module ready (not applied), secrets created, storage prepared, Traefik routes prepared

---

## Phase 3: User Story 1 - Safe Cluster Reduction (Priority: P1)

**Goal**: Reduce 3-node ES cluster to single node on Hestia without data loss

**Independent Test**: Document count before and after matches exactly; all shards on hestia; cluster health green/yellow

### Implementation for User Story 1

- [ ] T022 [US1] Set all indices to 0 replicas via ES API `PUT /_all/_settings`
- [ ] T023 [US1] Create index template for 0 replicas via ES API `PUT /_index_template/single-node-template`
- [ ] T024 [US1] Exclude heracles and nyx from allocation via ES API `PUT /_cluster/settings`
- [ ] T025 [US1] Start async monitoring of shard relocation (nohup curl loop to /_cat/shards, log to /tmp/shard-relocation.log)
- [ ] T026 [US1] Poll shard relocation status until all shards on hestia (check /tmp/shard-relocation.log or query ES API)
- [ ] T027 [US1] Verify document count matches baseline from T002
- [ ] T028 [US1] Verify cluster health is green or yellow via ES API
- [ ] T029 [US1] Save verification results to specs/006-elk-k8s-migration/us1-verification.txt

**Checkpoint**: Cluster reduced to single node on Hestia, all data preserved, ready for data migration

---

## Phase 4: User Story 2 - Data Migration to Shared Storage (Priority: P2)

**Goal**: Copy ES data from local storage to GlusterFS, deploy on K8s

**Independent Test**: ES pod starts on K8s, all indices accessible, document count matches baseline

**Dependencies**: Requires US1 complete (all shards on Hestia)

### Implementation for User Story 2

- [ ] T030 [US2] Stop Nomad ELK job with `nomad job stop elk`
- [ ] T031 [US2] Start async rsync of ES data to GlusterFS via SSH with nohup: `nohup rsync -av /var/lib/elasticsearch/ /storage/v/glusterfs_elasticsearch_data/ > /tmp/rsync-es.log 2>&1 &`
- [ ] T032 [US2] Poll rsync progress by checking /tmp/rsync-es.log and comparing directory sizes until complete
- [ ] T033 [US2] Fix ownership with `chown -R 1000:1000 /storage/v/glusterfs_elasticsearch_data/` via SSH
- [ ] T034 [US2] Verify data size matches source via SSH `du -sh` comparison
- [ ] T035 [US2] Apply K8s ELK module with `terraform apply -target='module.k8s_elk'`
- [ ] T036 [US2] Poll ES pod status until Running via kubectl (check elasticsearch-0 pod)
- [ ] T037 [US2] Activate external Traefik routes: uncomment k8s-es and k8s-kibana routers in /mnt/docker/traefik/traefik/dynamic_conf.yml via SSH (Traefik auto-reloads)
- [ ] T038 [US2] Wait for ES to be ready by polling `/_cluster/health` via external URL https://es.brmartin.co.uk
- [ ] T039 [US2] Verify document count matches baseline from T002 via ES API
- [ ] T040 [US2] Verify all indices accessible via ES API `/_cat/indices`
- [ ] T041 [US2] Save verification results to specs/006-elk-k8s-migration/us2-verification.txt

**Checkpoint**: ES running on K8s with all data intact, ready for Kibana verification

---

## Phase 5: User Story 3 - Kubernetes Deployment Verification (Priority: P3)

**Goal**: Verify full ELK stack functionality on K8s including log ingestion

**Independent Test**: Kibana UI loads, dashboards work, new logs appear within 5 minutes

**Dependencies**: Requires US2 complete (ES running on K8s)

### Implementation for User Story 3

- [ ] T042 [US3] Poll Kibana pod status until Running via kubectl
- [ ] T043 [US3] Verify Kibana external URL accessible via curl to https://kibana.brmartin.co.uk
- [ ] T044 [US3] Verify Kibana can connect to ES by checking Kibana logs for successful connection
- [ ] T045 [US3] Wait 5 minutes for log ingestion, then query ES API for logs with @timestamp > now-5m
- [ ] T046 [US3] Verify new logs appearing in ES via API query
- [ ] T047 [US3] Test ES external URL with curl to https://es.brmartin.co.uk/_cluster/health
- [ ] T048 [US3] Verify Filebeat connectivity by checking log volume in ES
- [ ] T049 [US3] Save verification results to specs/006-elk-k8s-migration/us3-verification.txt

**Checkpoint**: Full ELK stack operational on K8s, log ingestion working, ready for Nomad cleanup

---

## Phase 6: User Story 4 - Nomad Decommissioning (Priority: P4)

**Goal**: Clean removal of ELK from Nomad, archive original data

**Independent Test**: No Nomad ELK jobs running, Terraform state clean, original data archived

**Dependencies**: Requires US3 complete (K8s deployment verified for 24+ hours recommended)

### Implementation for User Story 4

- [ ] T050 [US4] Verify K8s ELK has been stable for sufficient time (check pod restart count, ES health history)
- [ ] T051 [US4] Remove module.elk from Terraform state with `terraform state rm module.elk`
- [ ] T052 [US4] Delete Nomad module files at modules/elk/
- [ ] T053 [US4] Remove module.elk declaration from main.tf
- [ ] T054 [US4] Run `terraform plan` to verify no Nomad-related changes pending
- [ ] T055 [US4] Archive original ES data on Hestia: `mv /var/lib/elasticsearch /var/lib/elasticsearch.bak` via SSH
- [ ] T056 [US4] Update AGENTS.md to reflect ELK migration to K8s (remove from Nomad section, add to K8s section)
- [ ] T057 [US4] Save final verification to specs/006-elk-k8s-migration/us4-verification.txt

**Checkpoint**: Nomad completely decommissioned for ELK, original data archived

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and cleanup

- [ ] T058 [P] Compile all verification files into specs/006-elk-k8s-migration/migration-report.md
- [ ] T059 [P] Update docs/ if any ELK-specific documentation exists
- [ ] T060 Remove archived ES data after 7 days stable operation: `rm -rf /var/lib/elasticsearch.bak` via SSH
- [ ] T061 Run final terraform plan to confirm clean state
- [ ] T062 Create git commit with all changes on branch 006-elk-k8s-migration

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on T007 (Vault secrets) from Setup
- **US1 (Phase 3)**: Depends on Setup completion (baseline recorded)
- **US2 (Phase 4)**: Depends on US1 completion (shards on Hestia) AND Foundational (K8s module ready)
- **US3 (Phase 5)**: Depends on US2 completion (ES running on K8s)
- **US4 (Phase 6)**: Depends on US3 completion + 24hr stability period
- **Polish (Phase 7)**: Depends on US4 completion

### User Story Dependencies

```
Setup (Phase 1)
    |
    v
Foundational (Phase 2) ----+
    |                      |
    v                      |
US1: Cluster Reduction     |
    |                      |
    +<---------------------+
    |
    v
US2: Data Migration + K8s Deploy
    |
    v
US3: Full Verification
    |
    v (24hr wait recommended)
US4: Nomad Cleanup
    |
    v
Polish (Phase 7)
```

### Within Each User Story

- Verification steps MUST pass before proceeding to next story
- Long-running operations (rsync, shard relocation) use async execution with polling
- Checkpoints serve as manual verification gates

### Parallel Opportunities

**Phase 1 (Setup)**:
```
T003, T004, T005, T006 can run in parallel (all read-only checks)
```

**Phase 2 (Foundational)**:
```
T009, T010 can run in parallel (different files)
T018, T019 can run in parallel (different K8s secrets)
```

**Phase 7 (Polish)**:
```
T058, T059 can run in parallel (different files)
```

---

## Parallel Example: Phase 1 Setup Verification

```bash
# Launch all verification checks together:
Task: "Verify cluster health is GREEN via ES API /_cluster/health"
Task: "Verify all 3 ES nodes present via ES API /_cat/nodes"
Task: "Check disk space on Hestia via ES API /_cat/allocation"
Task: "Check GlusterFS space via SSH to 192.168.1.5"
```

## Parallel Example: Phase 2 Module Creation

```bash
# Launch initial module files together:
Task: "Create modules-k8s/elk/versions.tf"
Task: "Create modules-k8s/elk/variables.tf"

# After main.tf complete, launch secrets in parallel:
Task: "Create K8s secret elasticsearch-certs"
Task: "Create K8s secret kibana-certs"
```

---

## Implementation Strategy

### MVP First (User Story 1 + 2)

1. Complete Phase 1: Setup - Verify prerequisites
2. Complete Phase 2: Foundational - K8s module ready (not applied)
3. Complete Phase 3: User Story 1 - Cluster reduced to single node
4. Complete Phase 4: User Story 2 - Data migrated, ES on K8s
5. **STOP and VALIDATE**: ES accessible, document count matches
6. Can operate with Kibana on Nomad temporarily if US3 blocked

### Incremental Delivery

1. Setup + Foundational → Infrastructure ready
2. US1 → Cluster reduced → Verify data intact
3. US2 → ES on K8s → Verify indices accessible
4. US3 → Full stack on K8s → Verify log ingestion
5. US4 (after 24hr) → Nomad cleanup → Migration complete

### Rollback Points

- **Before T030 (Nomad stop)**: Can re-enable nodes, restore replicas
- **After T030, before T035**: Restart Nomad job from original data
- **After T035 (K8s deploy)**: Delete K8s resources, revert Traefik config, restart Nomad from /var/lib/elasticsearch

---

## Async Operation Patterns

### Shard Relocation Monitoring (T025-T026)

```bash
# Start async monitoring
nohup bash -c 'while true; do 
  curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
    "https://es.brmartin.co.uk/_cat/shards?v" | grep -v hestia >> /tmp/shard-relocation.log
  sleep 30
  # Exit when all shards on hestia
  if ! curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
    "https://es.brmartin.co.uk/_cat/shards?v" | grep -v hestia | grep -v "^index" | grep -q .; then
    echo "COMPLETE: All shards on hestia" >> /tmp/shard-relocation.log
    exit 0
  fi
done' &

# Poll for completion
while ! grep -q "COMPLETE" /tmp/shard-relocation.log; do
  tail -5 /tmp/shard-relocation.log
  sleep 60
done
```

### Data Migration Monitoring (T031-T032)

```bash
# Start async rsync via SSH
/usr/bin/ssh 192.168.1.5 'nohup rsync -av --progress \
  /var/lib/elasticsearch/ \
  /storage/v/glusterfs_elasticsearch_data/ \
  > /tmp/rsync-es.log 2>&1 &'

# Poll for completion
while /usr/bin/ssh 192.168.1.5 'pgrep -f "rsync.*elasticsearch"' >/dev/null; do
  /usr/bin/ssh 192.168.1.5 'tail -3 /tmp/rsync-es.log'
  /usr/bin/ssh 192.168.1.5 'du -sh /storage/v/glusterfs_elasticsearch_data/'
  sleep 30
done
echo "rsync complete"
```

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks
- [Story] label maps task to specific user story for traceability
- Long-running operations use nohup/background with polling
- Verification files created at each checkpoint for audit trail
- 24hr stability wait before US4 is recommended but not enforced
- Original data archived (not deleted) until 7 days post-migration
- External Traefik routes must be activated (T037) for external URLs to work after migration
- Total tasks: 62 (T001-T062)
