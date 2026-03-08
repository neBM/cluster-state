# Tasks: ELK to Loki Migration

**Input**: Design documents from `/specs/011-loki-migration/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/component-interfaces.md, quickstart.md

**Organization**: Tasks grouped by user story to enable independent implementation and testing. No automated tests — manual verification via `kubectl` and Grafana Explore as documented in quickstart.md.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create module directories and MinIO pre-conditions that must exist before Terraform can deploy anything.

- [x] T001 Create `modules-k8s/loki/` directory with empty `main.tf` and `variables.tf` stubs
- [x] T002 [P] Create `modules-k8s/alloy/` directory with empty `main.tf` and `variables.tf` stubs
- [x] T003 Manually create MinIO `loki` user, `loki-policy`, and `loki` bucket via MinIO Console at https://minio.brmartin.co.uk (see quickstart.md Phase 1)
- [x] T004 Create Kubernetes Secret `loki-minio` in `default` namespace with `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY` via `kubectl create secret generic` (see quickstart.md §1.2)

**Checkpoint**: `kubectl get secret loki-minio -n default` succeeds; MinIO bucket `loki` exists.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `loki` K8s Service (ClusterIP) must exist before Alloy and Grafana can reference it. Deploy Loki first, then Alloy, then Grafana datasource update.

**⚠️ CRITICAL**: US1 (Grafana Explore) and US2 (container log collection) both require Loki running and Alloy running before they can be validated.

- [x] T005 Implement `modules-k8s/loki/variables.tf` — declare all input variables: `image_tag` (default `"3.4.1"`), `minio_endpoint`, `minio_bucket`, `minio_secret_name`, `retention_period` (default `"720h"`), `namespace` (default `"default"`)
- [x] T006 Implement `modules-k8s/loki/main.tf` — `kubernetes_config_map` containing `loki.yaml` with the full confirmed config from research.md (auth_enabled, server ports, schema TSDB v13, storage_config.aws pointing to MinIO, ingester WAL on emptyDir, compactor retention 720h)
- [x] T007 Add `kubernetes_deployment` to `modules-k8s/loki/main.tf` — 1 replica, `Recreate` strategy, image `grafana/loki:${var.image_tag}`, mounts ConfigMap at `/etc/loki/loki.yaml`, `emptyDir` at `/loki` (covers WAL + index + compactor), env vars `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from Secret `loki-minio`, readinessProbe `GET /ready` port 3100
- [x] T008 Add `kubernetes_service` to `modules-k8s/loki/main.tf` — ClusterIP, port 3100 (HTTP), name `loki`, namespace `default`
- [x] T009 Add `module "k8s_loki"` block to `kubernetes.tf` with all required variables (namespace, minio_endpoint, minio_bucket, minio_secret_name, retention_period)
- [x] T010 Run `terraform plan -target='module.k8s_loki' -out=tfplan && terraform apply tfplan`; verify `kubectl get pod -l app.kubernetes.io/name=loki -n default` shows Running and `/ready` returns `"ready"`

**Checkpoint**: Loki pod Running; `kubectl exec … wget -qO- http://localhost:3100/ready` returns `ready`.

---

## Phase 3: User Story 2 — All Kubernetes Container Logs Collected (Priority: P1)

**Goal**: Alloy DaemonSet running on all 3 nodes, tailing `/var/log/pods`, pushing to Loki with required labels.

**Independent Test**: Query `{namespace="default", container="traefik"}` in Grafana Explore (or via `kubectl exec` into Loki pod using the query API) — log lines appear within 60 seconds of emission.

- [x] T011 [US2] Implement `modules-k8s/alloy/variables.tf` — declare `image_tag` (default `"v1.7.1"`), `loki_url`, `namespace` (default `"default"`)
- [x] T012 [US2] Add `kubernetes_service_account` resource to `modules-k8s/alloy/main.tf` — name `alloy`, namespace `default`
- [x] T013 [P] [US2] Add `kubernetes_cluster_role` to `modules-k8s/alloy/main.tf` — rules: `get/list/watch` on `nodes`, `pods`, `services`, `endpoints`, `namespaces`; `get` on `nodes/proxy`
- [x] T014 [US2] Add `kubernetes_cluster_role_binding` to `modules-k8s/alloy/main.tf` — binds `ClusterRole/alloy` to `ServiceAccount/alloy`
- [x] T015 [US2] Add `kubernetes_config_map` to `modules-k8s/alloy/main.tf` — key `config.alloy`, value containing the full Alloy pipeline: `discovery.kubernetes "pods"`, `discovery.relabel "pod_logs"` (extracts namespace/pod/container/node labels, constructs `__path__`), `local.file_match "pod_logs"`, `loki.source.file "pod_logs"`, `loki.process "pod_logs"` (CRI parse + drop kube-probe + drop health-check noise + add cluster label `k3s-homelab`), `loki.write "loki"` pointing to `var.loki_url`
- [x] T016 [US2] Add `kubernetes_daemon_set_v1` to `modules-k8s/alloy/main.tf` — image `grafana/alloy:${var.image_tag}`, runs as root (for `/var/log/auth.log`), tolerates `node-role.kubernetes.io/control-plane` taint, mounts: `/var/log/pods` (hostPath, readOnly), `/var/log` (hostPath, readOnly), `alloy-positions` hostPath DirectoryOrCreate at `/var/lib/alloy` (readWrite); ConfigMap `alloy-config` at `/etc/alloy/config.alloy`
- [x] T017 [US2] Add `kubernetes_service` to `modules-k8s/alloy/main.tf` — ClusterIP, port 12345 (Alloy HTTP metrics), annotations `prometheus.io/scrape=true`, `prometheus.io/port=12345`
- [x] T018 [US2] Add `module "k8s_alloy"` block to `kubernetes.tf` — namespace `default`, loki_url `http://loki.default.svc.cluster.local:3100/loki/api/v1/push`
- [x] T019 [US2] Run `terraform plan -target='module.k8s_alloy' -out=tfplan && terraform apply tfplan`; verify `kubectl get pods -l app.kubernetes.io/name=alloy -n default -o wide` shows 3 pods (one per node: hestia, heracles, nyx)
- [x] T020 [US2] Validate US2: check Alloy logs for "discovered N targets" and successful sends; run quickstart.md §5.1 LogQL queries for `{node="hestia"}`, `{node="heracles"}`, `{node="nyx"}` and `{namespace="default", container="traefik"}`; confirm kube-probe noise filter returns zero results

**Checkpoint**: All 3 nodes have logs in Loki; `{namespace="default"}` returns entries; `{namespace="default"} |= "kube-probe"` returns zero.

---

## Phase 4: User Story 1 — Browse and Search Logs in Grafana Explore (Priority: P1)

**Goal**: Grafana has a working Loki datasource so operators can query logs via Grafana Explore.

**Independent Test**: Open Grafana Explore → select Loki → filter `{namespace="default", container="gitlab-webservice"}` → log lines appear with correct timestamps.

**Depends on**: T010 (Loki running), T019 (Alloy running and shipping logs)

- [x] T021 [US1] Add `loki_url` variable to `modules-k8s/grafana/variables.tf` — type string, default `"http://loki.default.svc.cluster.local:3100"`
- [x] T022 [US1] Update `modules-k8s/grafana/main.tf` — add `"loki.yaml"` key to the `kubernetes_config_map.datasources` resource `data` map, value is `yamlencode({apiVersion=1, datasources=[{name="Loki", type="loki", uid="loki", access="proxy", url=var.loki_url, isDefault=false, editable=true, jsonData={maxLines=1000, timeout=60}, version=1}]})`. Do NOT add `X-Scope-OrgID` header.
- [x] T023 [US1] Update `module "k8s_grafana"` block in `kubernetes.tf` — add `loki_url = "http://loki.default.svc.cluster.local:3100"`
- [x] T024 [US1] Run `terraform plan -target='module.k8s_grafana' -out=tfplan && terraform apply tfplan`; then `kubectl rollout restart deployment/grafana -n default && kubectl rollout status deployment/grafana -n default`
- [x] T025 [US1] Validate US1: open https://grafana.brmartin.co.uk → Connections → Data Sources → confirm "Loki" datasource shows "Data source is working"; run acceptance scenarios from spec.md US1 in Grafana Explore: text search `|= "error"`, time range scoping, container filter for `gitlab-webservice`

**Checkpoint**: Loki datasource passes health check in Grafana; log queries return results within expected latency.

---

## Phase 5: User Story 3 — System and Host Logs Collected (Priority: P2)

**Goal**: Alloy DaemonSet extended with journal and syslog collection pipelines.

**Independent Test**: SSH to any node, run `logger "loki-test-$(date +%s)"`, then query `{job="node/syslog"}` in Grafana Explore — entry appears.

**Depends on**: T019 (Alloy DaemonSet deployed)

- [x] T026 [US3] Update `modules-k8s/alloy/main.tf` ConfigMap — extend `config.alloy` to add journal collection pipeline: `loki.source.journal "journal"` reading from `/var/log/journal` and `/run/log/journal`, extracting `unit` and `level` labels, static label `job="journal"`, node label from `HOSTNAME` env var; forward to `loki.write "loki"`
- [x] T027 [US3] Update `modules-k8s/alloy/main.tf` ConfigMap — extend `config.alloy` to add syslog/auth pipeline: `local.file_match "host_logs"` targeting `/var/log/syslog` and `/var/log/auth.log`; `loki.source.file "host_logs"` with static labels `job="node/syslog"` / `job="node/auth"` respectively; forward to `loki.write "loki"`
- [x] T028 [US3] Update `modules-k8s/alloy/main.tf` DaemonSet — add hostPath mounts: `/var/log/journal` (readOnly), `/run/log/journal` (readOnly) (note: `/var/log` mount already added in T016 covers syslog/auth.log)
- [x] T029 [US3] Run `terraform plan -target='module.k8s_alloy' -out=tfplan && terraform apply tfplan`; restart Alloy: `kubectl rollout restart daemonset/alloy -n default`
- [x] T030 [US3] Validate US3: query `{job="journal"} | unit="k3s.service"` in Grafana Explore — results present; SSH to a node, generate syslog entry, verify in `{job="node/syslog"}`; verify auth log appears in `{job="node/auth"}` (quickstart.md §5.1)

**Checkpoint**: Journal and syslog entries visible in Grafana Explore with correct labels.

---

## Phase 6: User Story 4 — Traefik Access Logs Collected (Priority: P2)

**Goal**: Confirm Traefik access logs flow through the pod log pipeline automatically (no extra config needed per research.md).

**Independent Test**: Make an HTTP request through Traefik, then query `{namespace="default", container="traefik"}` — access log line with method, path, and status visible.

**Depends on**: T020 (Alloy running and tailing pod logs)

- [x] T031 [US4] Validate US4 (no code change required): make an HTTP request to any Traefik-routed service; query `{namespace="default", container="traefik"}` in Grafana Explore within 60 seconds; confirm access log line is present with HTTP method, path, and status code (quickstart.md §5.1)

**Note**: No implementation task needed — Traefik writes to stdout → containerd → `/var/log/pods` → picked up by existing Alloy pod pipeline (confirmed in research.md). This phase is a validation-only checkpoint.

**Checkpoint**: Traefik access log entries visible in Loki with `container="traefik"` label.

---

## Phase 7: User Story 6 — Log Retention Configured (Priority: P2)

**Goal**: Verify 30-day compactor retention is active and correctly configured.

**Independent Test**: Query Loki `/config` endpoint for `retention_period: 720h` and `/metrics` for compactor running.

**Depends on**: T010 (Loki running)

- [x] T032 [US6] Validate US6 retention config: `kubectl exec -n default -l app.kubernetes.io/name=loki -- wget -qO- http://localhost:3100/config | grep retention` — confirms `retention_period: 720h` and `retention_enabled: true`; check `loki_compactor_apply_retention_last_successful_run_timestamp_seconds` metric is non-zero (quickstart.md §7.2)

**Note**: Retention is already coded into the `loki.yaml` ConfigMap in T006. This phase verifies it is live. No additional code changes needed.

**Checkpoint**: Loki `/config` shows `retention_period: 720h`; compactor metric confirms retention is running.

---

## Phase 8: User Story 5 — Cluster RAM Freed After Decommission (Priority: P1)

**Goal**: Remove ELK stack (Elasticsearch, Kibana, Elastic Agent, Fleet Server) from Terraform, free ~11 GB RAM and 100 GB NVMe.

**⚠️ GATE**: Only proceed after Phases 3–7 validation is complete and Loki coverage is confirmed satisfactory.

**Independent Test**: `kubectl top nodes` shows Heracles below 75% RAM; no elasticsearch/kibana/elastic-agent pods exist.

- [x] T033 [US5] Remove `module "k8s_elk"` block from `kubernetes.tf`
- [x] T034 [P] [US5] Remove `module "k8s_elastic_agent"` block from `kubernetes.tf`
- [x] T035 [US5] Run `terraform plan -out=tfplan` — review plan carefully: should show destruction of all ELK and elastic-agent K8s resources (StatefulSets, Deployments, DaemonSets, PVCs, IngressRoutes, Secrets, ClusterRoles, Namespace/elastic-system)
- [x] T036 [US5] Run `terraform apply tfplan` to decommission ELK stack
- [x] T037 [US5] Delete Elasticsearch PVCs to reclaim NVMe: `kubectl delete pvc elasticsearch-data-elasticsearch-data-0 elasticsearch-data-elasticsearch-data-1 -n default`; SSH to Hestia/Heracles and remove retained PV directories (see quickstart.md §6.3)
- [x] T038 [US5] Delete lingering `elastic-system` namespace if empty: `kubectl delete namespace elastic-system`
- [x] T039 [P] [US5] Delete `modules-k8s/elk/` directory entirely (all `.tf` files) — no longer referenced by Terraform after T033
- [x] T040 [P] [US5] Delete `modules-k8s/elastic-agent/` directory entirely (all `.tf` files) — no longer referenced by Terraform after T034
- [x] T041 [US5] Validate US5: `kubectl top nodes` — Heracles below 75%; `kubectl get pods -n default | grep -E 'elasticsearch|kibana'` returns nothing; `kubectl get pods -n elastic-system` returns nothing; `kubectl get pods -n kube-system | grep elastic` returns nothing; run final acceptance query set from quickstart.md §7.3

**Checkpoint**: Heracles RAM below 75%; no ELK pods, PVCs, namespaces, or module directories remain; all P1 LogQL acceptance scenarios pass.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [x] T042 [P] Update `AGENTS.md` "Recent Changes" section — add entry: `011-loki-migration: Replaced 3-node Elasticsearch + Kibana + Elastic Agent with Grafana Loki (monolithic, MinIO-backed) + Grafana Alloy DaemonSet`
- [x] T043 [P] Update `AGENTS.md` "Services (K8s)" table — remove `elk` and `elastic-agent` rows; add `loki` (Deployment) and `alloy` (DaemonSet) rows; update Grafana row to note Loki datasource
- [x] T044 [P] Update `AGENTS.md` "Observability" section — replace Elasticsearch log query examples with Grafana/Loki equivalents; remove Kibana and Elasticsearch from the Links section
- [x] T045 Verify Prometheus metrics scraping of Alloy: check `kubectl get svc alloy -n default -o yaml` shows scrape annotations; confirm VictoriaMetrics picks up Alloy metrics at `victoriametrics.brmartin.co.uk`
- [x] T046 Run complete quickstart.md validation checklist (all phases) as final acceptance sign-off

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately. T001 and T002 can run in parallel.
- **Phase 2 (Foundational/Loki)**: Depends on Phase 1 (T003, T004 must complete first). Loki must be running before Alloy or Grafana can be validated.
- **Phase 3 (US2 - Alloy/Container Logs)**: Depends on Phase 2 (Loki Service must exist). Alloy must ship logs before US1 Grafana validation makes sense.
- **Phase 4 (US1 - Grafana Explore)**: Depends on Phase 2 and Phase 3. Loki datasource validates only when logs are flowing.
- **Phase 5 (US3 - Host Logs)**: Depends on Phase 3 (Alloy DaemonSet deployed). Extends existing Alloy config.
- **Phase 6 (US4 - Traefik)**: Depends on Phase 3. Validation-only, no code change.
- **Phase 7 (US6 - Retention)**: Depends on Phase 2. Validation-only.
- **Phase 8 (US5 - Decommission)**: MUST come last. Gate: all prior phases validated.
- **Phase 9 (Polish)**: After Phase 8. T042, T043, T044, T045 can run in parallel.

### User Story Dependencies

| Story | Phase | Priority | Depends On |
|-------|-------|----------|------------|
| US2 - Container Logs | 3 | P1 | Loki running (Phase 2) |
| US1 - Grafana Explore | 4 | P1 | US2 logs flowing |
| US3 - Host Logs | 5 | P2 | Alloy DaemonSet (US2) |
| US4 - Traefik Logs | 6 | P2 | Alloy DaemonSet (US2) |
| US6 - Retention | 7 | P2 | Loki running (Phase 2) |
| US5 - Decommission | 8 | P1 | All other stories validated |

### Parallel Opportunities

- T001 and T002 (module directory creation) — parallel
- T012 and T013 (ClusterRole + ServiceAccount) — parallel
- T033 and T034 (remove elk + elastic-agent from kubernetes.tf) — parallel
- T039 and T040 (delete elk + elastic-agent module directories) — parallel, after T036 apply
- T042, T043, T044, T045 (AGENTS.md updates + metrics check) — parallel
- Phases 5, 6, 7 can proceed in parallel once Phase 3 (Alloy DaemonSet) is complete

---

## Parallel Example: Phase 3 (US2 Alloy)

```
# These tasks can run in parallel (different resources, same file is OK with care):
Task T012: kubernetes_service_account in alloy/main.tf
Task T013: kubernetes_cluster_role in alloy/main.tf
```

```
# These must be sequential:
T013 → T014 (ClusterRoleBinding references ClusterRole)
T015 → T016 (DaemonSet references ConfigMap)
T016 → T018 → T019 (module wired in kubernetes.tf before apply)
```

---

## Implementation Strategy

### MVP First (US1 + US2 — the P1 stories that deliver logging)

1. Complete Phase 1: MinIO setup + secret
2. Complete Phase 2: Loki running
3. Complete Phase 3: Alloy shipping container logs
4. Complete Phase 4: Grafana datasource
5. **STOP and VALIDATE**: Confirm logs visible in Grafana Explore (quickstart.md §5)
6. If satisfied, proceed to decommission (Phase 8) immediately — US3/US4/US6 are P2 and can follow

### Full Migration (all stories)

1. MVP (above) → Phases 5–7 (host logs, Traefik, retention verification)
2. Phase 8: Decommission ELK once all P2 stories confirmed
3. Phase 9: Documentation cleanup

### Rollback

If Loki is not performing acceptably during Phase 3–4 validation:
- Do NOT proceed to Phase 8 (ELK remains fully operational)
- Scale Loki to 0: `kubectl scale deployment loki -n default --replicas=0`
- Fix and redeploy
- Existing Elastic Agent continues collecting logs throughout

---

## Notes

- No automated tests — all validation is manual via `kubectl` and Grafana Explore as documented in quickstart.md
- [P] tasks = different Terraform resources or files, no sequential dependency
- MinIO Secret (`loki-minio`) must be created manually before `terraform apply` for the Loki module (Terraform does not manage secret values)
- Do NOT set `X-Scope-OrgID` header in the Grafana Loki datasource — `auth_enabled: false` uses `"fake"` tenant automatically
- Do NOT use `ignore_changes` lifecycle blocks (AGENTS.md constraint)
- WAL must NOT be on GlusterFS/NFS — `emptyDir` is correct for both Loki and Alloy
