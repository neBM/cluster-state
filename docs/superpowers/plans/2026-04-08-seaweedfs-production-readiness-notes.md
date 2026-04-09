# SeaweedFS Production Readiness — Planning Notes

> **Gap #2 shipped 2026-04-09** — `seaweedfs-consumer-recycler` DaemonSet (v0.1.1) deployed and validated on all 3 nodes (hestia amd64, heracles + nyx arm64). Path A (event-driven, on `seaweedfs-mount` restart) and Path B (stat-prober for stale FUSE mounts) both firing in production.

> **Status:** Context dump, not yet a plan. Each item below should become its own plan doc (`/superpowers:brainstorm` then `/superpowers:write-plan`) when picked up for implementation. Written 2026-04-08 after `seaweedfs-mount` split shipped; captures residual gaps while context is hot.

**Prior work shipped (2026-04-08):**
- `seaweedfs-mount` now runs in its own DaemonSet (`OnDelete` strategy); CSI v1.4.8-split images built and sideloaded to all 3 nodes.
- Reconcile race fixed (`pkg/mountmanager/reconcile.go` unconditionally lazy-unmounts at startup).
- Key success criterion verified: deleting `seaweedfs-csi-node` pod does NOT disturb FUSE sessions or consumer mounts.
- See memory `project_seaweedfs_reconcile_propagation_2026_04_08.md` for full status.

**Key discovery worth knowing before planning:** Upstream seaweedfs-csi-driver helm chart already ships a separate `daemonset-mount.yaml` (`~/Documents/Personal/projects/seaweedfs-csi-driver/deploy/helm/seaweedfs-csi-driver/templates/daemonset-mount.yaml`). Our work re-implemented this in native Terraform. Worth reading upstream's version before planning new controller work — they may already have patterns we can lift.

---

## Gap 1: No FUSE session recovery (fundamental) — **RESEARCH-ONLY**

**Not plannable as tasks.** Multi-month architectural project. Three paths:
- Upstream weed mount: serialize FUSE session state, pass `/dev/fuse` FDs to new process. Nobody working on this upstream.
- Per-pod FUSE sidecar: run weed mount inside each consumer (CSI ephemeral volume / initContainer). Eliminates shared daemon. Loses cross-pod caching.
- Switch CSI driver: s3fs-fuse in each pod, or S3 CSI driver → seaweedfs S3 gateway. Different perf/POSIX trade-offs.

**Action:** Research doc only. Not pursuing in-house.

---

## Gap 2: No automated consumer recovery on mount restart — **SHIPPED 2026-04-09**

**Shipped as:** `seaweedfs-consumer-recycler` DaemonSet at `modules-k8s/seaweedfs/consumer-recycler.tf`. Image `registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:v0.1.1` (multi-arch: amd64 + arm64, sideloaded — registry is backed by SeaweedFS). Plan: `docs/superpowers/plans/2026-04-08-seaweedfs-consumer-recycler.md`.

**How it works:**
- **Path A (event-driven):** Watches `seaweedfs-mount` pods via controller-runtime. On restart detection (pod recreate or restartCount increment), emits `RecycleTriggered` K8s event and cycles all consumer pods on that node via Eviction API with a 5s stagger. 60s cold-start grace after recycler startup prevents false-triggering on its own boot.
- **Path B (stat-prober):** Every 30s, probes each `fuse.seaweedfs` mountpoint from `/proc/self/mountinfo`. On probe failure, emits `RecycledStaleMount` event and cycles the single consumer holding the broken mount. Catches crash-recovery edge cases that Path A misses (e.g. FUSE session death without pod restart).

**Validated in production (2026-04-09):**
- Hestia (amd64): 7 consumer pods cycled cleanly on forced mount-pod restart
- Heracles (arm64): 12 consumer pods cycled cleanly on forced mount-pod restart
- Nyx (arm64): 10 evictions recorded live earlier the same day (Path A event-driven)
- Metrics: `cycles_total`, `triggers_total{path=event|probe}` exposed on `:9090/metrics`

**Follow-ups (non-blocking):**
- Makefile container-recycler target is host-arch only — future improvement: wire `docker buildx` for multi-arch builds.
- No CI build stage — every deploy has been manual sideload (chicken-and-egg: registry is backed by SeaweedFS).

---

### Original planning notes (preserved for history)

**Why it matters:** Even with reconcile.go unmounting orphans, busy consumer pods keep stale bind mounts because kernel `propagate_umount()` skips slaves with open FDs. Kubelet's VolumeManager only stats paths, never re-invokes NodePublishVolume. Currently relies on human running `kubectl delete pod`.

**Recommended approach:** Build a small in-cluster controller ("seaweedfs-consumer-recycler").

**Design constraints:**
- MUST trigger on `seaweedfs-mount` pod restart, NOT `seaweedfs-csi-node` restart (the whole point of the split was that csi-node restarts are safe).
- Identify affected consumers by: pods on the same node + PVC bound to storage class `seaweedfs` (or whatever driver label).
- Avoid thundering herd: rate-limit deletions, or stagger per node.
- Must survive its own restart without false-deleting on the initial reconcile.

**Options for implementation:**
1. **Go controller** using controller-runtime, watches Pod events filtered to `component=seaweedfs-mount`. ~200 LOC.
2. **Simple shell/Python cronjob**: every 30s, probe every `fuse.seaweedfs` mount via `stat`, delete pods holding broken ones. Simpler, more general (catches crash loops too), but polling-based.
3. **Lift from upstream:** check if chrislusf/seaweedfs-csi-driver or similar already has this.

**Key files to study before planning:**
- `~/Documents/Personal/projects/seaweedfs-csi-driver/deploy/helm/seaweedfs-csi-driver/templates/daemonset-mount.yaml` — upstream split pattern
- `~/Documents/Personal/projects/seaweedfs-csi-driver/pkg/driver/nodeserver.go:450` lines — `NodePublishVolume` re-invocation path

**Priority:** Build this before #3, because #3 alerts are noise if there's no automated remediation.

---

## Gap 3: Crash-loop protection / alerting

**Status of observation stack:** No existing `VMRule` / `PrometheusRule` / alerting rules in `iac/cluster-state` repo (confirmed via grep). VictoriaMetrics module exists (`modules-k8s/victoriametrics`) but alerting is either off or configured elsewhere.

**Planning notes:**
- Start with a new file `modules-k8s/seaweedfs/alerts.tf` or similar, adding a `kubectl_manifest` of kind `VMRule` (check VM operator CRD version first).
- Alerts to add:
  - `SeaweedFSMountRestart`: `increase(kube_pod_container_status_restarts_total{container="seaweedfs-mount"}[15m]) > 0`
  - `SeaweedFSMountDown`: `absent(up{job="seaweedfs-mount"})` (requires metrics scrape — depends on #6)
  - `SeaweedFSMountCrashLoop`: `rate(kube_pod_container_status_restarts_total{container="seaweedfs-mount"}[1h]) > 0.1`
- Need to confirm kube-state-metrics is scraped and provides these series. Check `modules-k8s/kube_state_metrics/`.
- Need AlertManager or VM Alert routing target. Check if configured anywhere — may not be.

**Blocker:** If AlertManager/VMAlert routing isn't set up cluster-wide, that's a prerequisite project of its own. Audit first.

**Priority:** After #2, before #6's deeper metrics.

---

## Gap 4: Cache directory unbounded growth

**Background:** `cache` volume moved from `emptyDir` to `hostPath /var/cache/seaweedfs` during the split. EmptyDir got wiped on pod restart; hostPath persists forever unless something cleans it.

**Investigation needed before planning:**
- Read `pkg/driver/nodeserver.go` — does `CleanupVolumeResources` (or the NodeUnpublishVolume path) actually rm the per-volume cache dir? Grep hits show the symbol exists in `nodeserver.go`, `utils.go`, `volume.go`.
- Measure current `/var/cache/seaweedfs` size on each node: `ssh ben@<ip> sudo du -sh /var/cache/seaweedfs`.
- Understand cache layout: is it `<volume-id>/chunks/` or flat?

**Options:**
1. If CleanupVolumeResources works: done. Just add a disk-size alert.
2. If not: add GC logic. Could be (a) a cronjob/systemd timer on the node, (b) a new goroutine in seaweedfs-mount, or (c) sidecar.

**Nice-to-have:** Configurable cache size cap in the driver. Check if `--cacheCapacityMB` flag exists.

**Priority:** Medium. Not acute unless disks fill.

---

## Gap 5: Startup ordering — csi-node dials socket before seaweedfs-mount ready

**Background:** `csi-seaweedfs` container in `csi-node` DaemonSet connects to `unix:///var/lib/seaweedfs-mount/seaweedfs-mount.sock`. After node reboot or first deploy, csi-node and seaweedfs-mount race. If csi-node starts first, the socket doesn't exist.

**Investigation needed:**
- Read `~/Documents/Personal/projects/seaweedfs-csi-driver/pkg/driver/mounter.go` (215 lines) — how does it dial the socket? Does it retry on ENOENT/ECONNREFUSED, or crash?
- Read `pkg/mountmanager/socket.go` — only 23 lines, probably just path constants. The actual client is likely in `mounter.go`.

**If crashes on dial failure:**
- Option A (driver fix): wrap dial in retry-with-backoff, e.g. 30 × 1s.
- Option B (terraform fix): add a startup probe or init container in csi-node that waits for the socket file to exist before starting `csi-seaweedfs`.
- Option A is cleaner; ship upstream.

**Test:** After planning the fix, validate by `sudo systemctl restart k3s` on a node and watching csi-node logs.

**Priority:** Will bite on the next node reboot. Worth doing early.

---

## Gap 6: Observability

**Planning notes:**
- Does `weed mount` expose Prometheus metrics? Check `weed mount -h` for a `-metricsPort` flag. If yes, add a Service + scrape config to the seaweedfs_mount DaemonSet.
- Metrics worth alerting on (in addition to #3):
  - `weed_mount_fuse_request_duration_seconds` (latency SLO)
  - `weed_mount_cache_hit_ratio`
  - FUSE session count per node
- **Canary probe:** a new DaemonSet `seaweedfs-canary` that runs on every node, has a PVC bound to a dedicated "canary" PV, writes a timestamped file every 30s and reads it back. Metric/probe: `seaweedfs_canary_last_success_seconds`. Alert if >2 minutes.
- Canary is the best black-box signal because it catches failures the CSI driver itself doesn't log.

**Priority:** Build canary before driver metrics — canary is easier and catches more.

---

## Gap 7: Upgrade runbook — **CHEAPEST, DO FIRST**

**Status:** No runbook exists. `OnDelete` strategy means operator-triggered; without documented procedure, each upgrade is ad-hoc.

**Deliverable:** Shell script at `scripts/seaweedfs-mount-upgrade.sh` or Ansible playbook. Procedure:

```
1. cd iac/cluster-state && terraform apply   # updates DS spec, no pods cycle yet
2. for node in nyx heracles hestia; do
     kubectl -n default delete pod -l component=seaweedfs-mount --field-selector=spec.nodeName=$node
     kubectl -n default wait --for=condition=Ready pod -l component=seaweedfs-mount,spec.nodeName=$node --timeout=120s
     # Cycle PVC consumers on this node
     kubectl get pods --all-namespaces -o json | \
       jq -r --arg n "$node" '.items[] | select(.spec.nodeName==$n and (.spec.volumes // [] | map(select(.persistentVolumeClaim)) | length > 0)) | "\(.metadata.namespace) \(.metadata.name)"' | \
       while read ns pod; do kubectl -n $ns delete pod $pod --wait=false; done
     sleep 120
     # Health probe
     ./scripts/seaweedfs-mount-probe.sh $node
   done
```

**Also needs:** `scripts/seaweedfs-mount-probe.sh` — execs into every PVC-holding pod on a node, stats `fuse.seaweedfs` mount points, reports BROKEN count. Already built this as a one-liner in the split plan; extract and commit.

**Priority:** Do this FIRST. No new moving parts, captures the procedure while fresh.

---

## Execution priority (recommended order)

| # | Item | Effort | Risk without it | Do it? |
|---|------|--------|-----------------|--------|
| 7 | Upgrade runbook + probe script | S | Every upgrade is ad-hoc | **First** |
| 5 | Driver socket retry | S | Breaks on node reboot | **Second** |
| 2 | Consumer-recycler controller | L | Every mount restart needs manual `kubectl delete` | **Third — biggest value** |
| 3 | Crash-loop alerting | S | Silent failures | After #2 (alerts need remediation) |
| 6 | Canary probe | M | Can't tell state without user reports | After #3 |
| 4 | Cache GC + disk alert | M | Disks fill slowly | Hygiene, when convenient |
| 1 | FUSE session recovery | ∞ | Research only | Don't pursue |

---

## Non-plan context worth preserving

- **Helm chart has split pattern:** `~/Documents/Personal/projects/seaweedfs-csi-driver/deploy/helm/seaweedfs-csi-driver/templates/daemonset-mount.yaml`. Read before designing anything new.
- **Driver file sizes (for future reads):** `pkg/mountmanager/socket.go` 23 lines, `pkg/driver/mounter.go` 215, `pkg/driver/nodeserver.go` 450, `pkg/driver/volume.go` 150.
- **No existing alerting rules** in `iac/cluster-state` repo — confirmed via grep of `VMRule|PrometheusRule|alerting_rules`. Either all rules live elsewhere or cluster has no alert routing set up. **Audit before assuming alerts land anywhere.**
- **No commit yet:** entire `modules-k8s/seaweedfs/` directory is untracked. Will be committed as part of the full migration landing, not per-change.
- **Kubernetes node propagation bug 2** (kernel `propagate_umount()` skips busy slaves) is the *why* behind #2 — HostToContainer propagation on consumer modules is functionally inert; can be cleaned up later but not urgent.
- **Driver branch:** `feat/volume-mount-group` on `~/Documents/Personal/projects/seaweedfs-csi-driver`, tip `a5b6029`. Any driver-side fixes (#5, maybe #4) add commits here.

---

## Next step

Pick one item, invoke `superpowers:brainstorming` to clarify scope, then `superpowers:writing-plans` to produce an executable plan. Recommend starting with **#7** (runbook — 1-hour job, captures procedural knowledge) or **#5** (socket retry — small focused driver fix, unblocks node reboots).
