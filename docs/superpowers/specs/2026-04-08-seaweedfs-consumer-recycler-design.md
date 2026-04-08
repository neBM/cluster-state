# SeaweedFS Consumer Recycler — Design Spec

**Status:** Design approved 2026-04-08. Not yet implemented.
**Addresses:** Gap #2 in `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`.
**Success criterion:** `seaweedfs-mount` pod restart no longer requires a human running `kubectl delete pod` on consumer pods.

## Problem

When the `seaweedfs-mount` DaemonSet pod is restarted (operator-triggered via the `OnDelete` strategy, or a crash), all `weed mount` subprocesses on that node die. Consumer pods on the node keep their bind mounts into `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/*/mount`, but those mounts now point at a dead FUSE session and return `ESHUTDOWN`/`EIO` on any I/O. The kernel's `propagate_umount()` skips slaves with open FDs, and kubelet's VolumeManager only `stat`s paths, never re-invoking `NodePublishVolume`. Result: consumer pods are wedged until a human deletes them by hand.

Nothing in upstream fixes this. The recent `seaweedfs-mount` split (v1.4.8-split, `pkg/mountmanager/reconcile.go`) stops CSI-node restarts from disturbing FUSE but does nothing for mount-daemon restarts themselves.

## Scope

In scope:
- Detect mount-daemon restart events on each node
- Detect broken FUSE mounts via periodic probing
- Cycle affected consumer pods via the Eviction API (delete fallback on PDB block)

Out of scope:
- FUSE session recovery (Gap #1, research-only, multi-month architectural project)
- Cache GC, alerting, canary probe, socket retry (Gaps #3-#7, separate plans)
- Fixing root-cause FUSE session serialization upstream

## Non-goals

- Not a generic CSI volume-health watcher. The recycler knows about `seaweedfs-csi-driver` specifically; it does not handle other CSI drivers.
- Not a distributed controller. Per-node scope, no cross-node coordination, no leader election.

## Architecture

**Topology.** DaemonSet, one pod per node. Each pod's scope is *only its own node* — all list/watch calls use `fieldSelector=spec.nodeName=$NODE_NAME`. A node going dark takes its recycler with it, which is correct — there is nothing on that node to remediate.

**Location.** `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/` (new `main.go` + `Dockerfile`) plus `drivers/seaweedfs-csi-driver/pkg/recycler/` (new package) in this repo. Shared `go.mod` with the rest of the driver. New image `registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:<tag>`. Terraform resources in a new `modules-k8s/seaweedfs/consumer-recycler.tf`.

**Two signal sources, one reconcile path.**

1. **Pod event (Path A).** controller-runtime informer filtered to `labels.component=seaweedfs-mount, spec.nodeName=$NODE_NAME`. Detects restart events (new pod UID reaching Ready, or in-place RestartCount bump).
2. **Periodic mount probe (Path B).** Ticker every 30s. Reads `/host/proc/self/mountinfo`, filters to `fuse.seaweedfs` entries under `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/*/mount`, runs `timeout 2 stat <mountpoint>` as a **subprocess** (not an in-process syscall — a hung `stat` would otherwise wedge the goroutine permanently). Failed/timed-out stat enqueues that specific mountpoint.

Both paths enqueue onto the same controller-runtime work queue, keyed so duplicates collapse (`node/mount-daemon` for Path A, `node/<mountpoint>` for Path B).

**Reconcile output.** Eviction API calls (with delete fallback), K8s events on cycled pods + source objects, Prometheus metrics, structured JSON logs.

## Components

```
drivers/seaweedfs-csi-driver/
├── cmd/
│   └── seaweedfs-consumer-recycler/
│       ├── main.go             # flag parsing, manager setup, signals
│       └── Dockerfile          # mirrors cmd/seaweedfs-mount/Dockerfile
└── pkg/
    └── recycler/
        ├── reconciler.go       # controller-runtime Reconciler for Path A
        ├── prober.go           # periodic mount health probe (Path B)
        ├── pvlookup.go         # PV/PVC → consumer pod mapping, CSI driver match
        ├── cycler.go           # eviction-first cycling with stagger + fallback
        ├── startup.go          # cold-start safety: baseline snapshot + grace window
        └── *_test.go
```

**Dependencies (direct, non-transitive):** `sigs.k8s.io/controller-runtime`, `k8s.io/client-go`, `k8s.io/api`, `k8s.io/apimachinery`, `github.com/prometheus/client_golang`. No hand-rolled K8s glue — the manager gives us informer caching, work queues, rate limiting, metrics endpoint, health probes, signal handling, and a clean Reconciler interface.

**Terraform (`modules-k8s/seaweedfs/consumer-recycler.tf`):**
- `kubernetes_service_account.consumer_recycler` — dedicated SA, not shared with `seaweedfs-csi`
- `kubernetes_cluster_role.consumer_recycler` + `kubernetes_cluster_role_binding` — `pods: list/watch/delete`, `pods/eviction: create`, `persistentvolumes: get/list/watch`, `persistentvolumeclaims: get/list`, `events: create/patch`
- `kubernetes_daemon_set_v1.consumer_recycler` — not privileged, `hostPID=false`, hostPath mounts for `/proc` (read-only) and `/var/lib/kubelet/pods` (read-only)
- `kubernetes_service.consumer_recycler_metrics` with `prometheus.io/scrape=true` annotations so VictoriaMetrics auto-discovers the scrape target
- New `variables.tf` entry: `consumer_recycler_image_tag`

## Reconciliation logic

**Path A — mount-daemon restart detection.** Filtered informer on `component=seaweedfs-mount, spec.nodeName=$NODE_NAME`. On each update, compare against the in-memory baseline for this pod UID:

- First observation of a UID → record baseline `{UID, RestartCount, StartedAt}`, do not react
- Pod UID changed (delete+recreate), new pod reaches Ready → restart event
- `seaweedfs-mount` container RestartCount incremented on the same UID → restart event
- Standalone pod deletion with no replacement Ready within 60s → ignored (node being drained)

**Path B — mount probe.** Every 30s:
1. Read `/host/proc/self/mountinfo`
2. Filter to `fuse.seaweedfs` entries under the kubelet CSI mount path pattern
3. For each, `exec.CommandContext(ctx, "stat", mountpoint)` with a 2s context timeout
4. Non-zero exit or context deadline → enqueue `<mountpoint>`

**Shared reconcile (triggered by either path):**
1. Enumerate pods on this node via informer cache
2. For each pod, resolve its PVCs → PVs, match on `PV.Spec.CSI.Driver == "seaweedfs-csi-driver"` (authoritative selector — not storage class name, not label)
3. Filter out: Terminating pods, `seaweedfs-mount` DS pods, the recycler's own pod
4. **Path A**: all matching pods are candidates (they all held FUSE sessions to the dead daemon, no subset is "fine")
5. **Path B**: resolve the failed mountpoint to a single pod UID via the `/var/lib/kubelet/pods/<pod-uid>/...` path structure, candidate list is just that one pod
6. Debounce: drop any candidate whose UID appears in the "recently cycled" map (TTL 120s)

**Cycling loop (stagger 5s between candidates):**
1. POST `policy/v1 Eviction` to `pods/eviction` with the pod's own `terminationGracePeriodSeconds`
2. 200 → success, emit `Warning RecycledStaleMount` event on the pod, add pod UID to the debounce map
3. 429 (PDB block) → exponential backoff, retry up to 30s wall clock
4. 30s of 429 → fall back to `DELETE --grace-period=0`, emit `Warning RecycleFallbackForced` with reason "eviction blocked by PDB for 30s, forced delete"
5. Sleep 5s, next candidate

## Startup safety

**The risk:** recycler restarts → informer initial sync → first observation of the mount-daemon pod. If we naively treat "first observation" as a restart event, a crash-looping recycler would cycle every consumer on the node every time it came up. That's catastrophic.

**Two layers of defense:**

1. **Baseline snapshotting.** First observation of a given `seaweedfs-mount` pod UID records `{UID, RestartCount, StartedAt}` in memory. Only subsequent changes to that tuple count as restart events. State is deliberately ephemeral — no persistence on disk or in a ConfigMap — because baseline is cheap to rebuild and persistence would add a correctness hazard (stale on-disk baselines).

2. **Cold-start grace window.** For the first 60s after recycler startup, **Path A is suppressed entirely**. Only Path B (probe) can trigger cycling during the grace window. Rationale: if the mount daemon genuinely *is* broken right now, the probe will catch it within 30s and remediate surgically (one mountpoint at a time). If the mount daemon is fine, the 60s suppression window prevents false positives from informer resyncs or replay.

The combination means: recycler cold start = probe-driven only for the first minute, event-driven after.

## Failure modes & error handling

| Scenario | Handling |
|---|---|
| Flapping mount daemon (rapid crash loop) | Debounce map (pod UID → last-cycled, TTL 120s). Repeat cycles of the same pod within 120s → skip + `Normal RecycleSkippedDebounce` event + metric. |
| Probe tick overlap with in-progress cycling | controller-runtime work queue dedupes by reconcile key; cycler is single-goroutine, processes one batch at a time. |
| Partial cycle interrupted by SIGTERM | In-memory state lost. On restart, cold-start window suppresses Path A for 60s, probe catches any still-broken mounts within 30s. Worst case ~30s delay. |
| Hung `stat` subprocess | `exec.CommandContext` with 2s timeout → SIGKILL on deadline → `Wait()` reaps. No zombies. |
| API server unreachable | controller-runtime informer exponential backoff. Path A suppressed if last successful sync >5min ago (don't act on stale cache). Path B keeps running — it only reads `/proc` + local kubelet dir, doesn't need the API server to detect problems, only to call eviction. Retries eviction until API returns. |
| Consumer with multiple seaweedfs PVCs | Single candidate, cycled once. Kubelet remounts all of its PVCs on recreate. |
| Pending consumer on this node with no mounts yet | Filtered out (no active mounts to break). |
| Recycler DS restarting | No seaweedfs PVCs on the recycler itself (mounts `/proc` + `/var/lib/kubelet/pods` read-only hostPath). Never a cycle candidate. Cold-start safety protects against its own restart. |
| Mount daemon scaled to zero (node drain) | No replacement Ready within 60s → no restart event fired. Cycling drained consumers would be pointless (kubelet drains them anyway). |

## Observability

**Kubernetes events:**
- Cycled consumer pod: `Warning RecycledStaleMount` (reason + mountpoint)
- `seaweedfs-mount` DS (Path A trigger): `Normal RecycleTriggered` (candidate count)
- Recycler DS (Path B trigger): `Normal ProbeFailure` (mountpoint + stat error)
- Debounced skip: `Normal RecycleSkippedDebounce`
- Forced delete fallback: `Warning RecycleFallbackForced`

**Prometheus metrics (`:9090/metrics`):**
- `seaweedfs_recycler_triggers_total{path="event|probe"}` counter
- `seaweedfs_recycler_cycles_total{outcome="evicted|forced|skipped"}` counter
- `seaweedfs_recycler_probe_duration_seconds` histogram
- `seaweedfs_recycler_probe_failures_total{reason="stat-timeout|stat-error|mountinfo-read"}` counter
- `seaweedfs_recycler_cold_start_suppressed_total` counter
- `seaweedfs_recycler_eviction_blocked_total{reason="pdb|other"}` counter
- Default controller-runtime + client-go + workqueue metrics (free via manager)

**Logs:** structured JSON to stdout. Alloy DaemonSet picks them up and ships to Loki. Query via Grafana Explore: `{namespace="default",container="seaweedfs-consumer-recycler"}`.

## Testing strategy

**Unit tests (table-driven, `pkg/recycler/*_test.go`):**
- `pvlookup`: pod/PVC/PV combinations, CSI driver name match, multi-PVC pods, mixed CSI+non-CSI volumes
- `cycler`: fake client (`sigs.k8s.io/controller-runtime/pkg/client/fake`), eviction attempted first, 429 triggers retry, 30s of 429 triggers force-delete, events emitted correctly
- `prober`: `/proc` mocked via tmpdir + `PROC_PATH` env var, subprocess timeout verified with a fake `stat` binary
- `startup`: baseline snapshot logic, first observation never triggers, incremented RestartCount on second observation triggers, cold-start window suppresses Path A

**Integration (`envtest`):** real `kube-apiserver` + `etcd` in-process (via controller-runtime's `envtest` package).
- Fake node, `seaweedfs-mount` pod, consumer pods with fake `seaweedfs-csi-driver` PVs
- Simulate restart by patching pod RestartCount
- Assert: expected eviction calls, cold-start window honored, debounce respected
- Assert: PDB block → force-delete fallback after 30s

**Out of scope for automated tests:** real FUSE mount breakage. Too hard to fake a wedged FUSE mount in CI, and the probe logic has a clean seam at the `stat` subprocess (inject a fake binary to simulate timeouts). Real FUSE behavior is validated during manual rollout.

**Coverage target:** ≥80% line coverage on `pkg/recycler/*`. No target on `cmd/seaweedfs-consumer-recycler/main.go` (wiring only).

## Rollout & acceptance

**Build pipeline:** `.gitlab-ci.yml` gains a `drivers-build` stage gated on `rules:changes: drivers/**`. Runs `go test ./...` then `go build` + image push. Image tagged `<short-sha>` plus `latest` on main.

**First deploy:**
1. Land Go code and tests in `drivers/seaweedfs-csi-driver/` (one commit)
2. Land terraform resources in `modules-k8s/seaweedfs/consumer-recycler.tf` with the image tag pinned to the commit from step 1
3. Targeted `terraform apply` to bring up the recycler DaemonSet before any broader apply
4. Observe: three recycler pods Ready, logs show `cold-start suppression active (60s)`, probe fires at 30s and finds zero broken mounts

**Acceptance test:**
1. Pick one node (e.g., nyx). Confirm baseline: all consumers on nyx Running with healthy FUSE mounts
2. `kubectl delete pod -n default -l component=seaweedfs-mount --field-selector=spec.nodeName=nyx`
3. Within ~60s: new `seaweedfs-mount` pod Ready; recycler logs `mount-daemon restarted on nyx, N candidates, stagger=5s`; K8s events on each consumer show `RecycledStaleMount`; eviction API calls succeed
4. Within ~5min: all consumers on nyx have new pods, all FUSE mounts healthy, zero manual `kubectl delete pod` invocations
5. Repeat for heracles and hestia

**Success criterion:** step 4 succeeds on all three nodes without human intervention.

**Rollback:** `terraform destroy -target=...consumer_recycler`. Cluster reverts to pre-work state — Gap #2 is back to manual, nothing else is worse.

## Open questions

None — all design decisions resolved during brainstorming.

## Deferred (not this spec)

- **Gap #3 alerting** depends on this work landing (alerts for unremediated failures are meaningful only once automatic remediation exists)
- **Gap #6 canary probe** complements this but is independent
- **CSI volume-health integration** (forward-looking): if our driver fork eventually implements `VolumeCondition` in `NodeGetVolumeStats`, the recycler can add it as a third signal source alongside Path A and Path B without rewriting the shared reconcile path. Out of scope for now.
