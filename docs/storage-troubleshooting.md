# Storage Troubleshooting

This runbook covers the current storage stack. GlusterFS and NFS-Ganesha were retired on May 30, 2026; historical notes live under `docs/archived/`.

## Current Storage Paths

| Storage | Use | Manifests |
|---------|-----|-----------|
| `seaweedfs` StorageClass | RWX PVCs and filer-backed app data | `infrastructure/storage/seaweedfs/`, app PVCs ending in `-sw` |
| SeaweedFS S3/COSI | Object buckets for backups, cache, and attachments | `infrastructure/storage/seaweedfs/cosi/` |
| `local-path` / `local-path-retain` | Node-local RWO data, especially database-heavy services | `infrastructure/storage/storage-classes/` |
| `synology-nfs-static` | Static read-only media shares | `apps/iris/`, `apps/media-centre/` |
| `restic-repository` static NFS PV/PVC | Existing `192.168.1.10:/volume1/csi/backups/restic` repository, mounted at `/repo` by both Restic CronJobs | `infrastructure/storage/restic-backup/` |

The Restic claim is prebound, RWX, and `Retain`, with no dynamic provisioning.
It exposes the same NAS directory previously mounted through Hestia's
`/mnt/csi/backups/restic`; no data migration or new repository is needed. Both
jobs can schedule without a hostname pin. The nominal `1Ti` PV/PVC size is
Kubernetes bookkeeping, not reserved NAS space or a quota. `storage-backups`
uses `prune: false`, so reverting the manifests does not remove this PV/PVC.

## First Checks

```bash
kubectl get pods -n default -l app=seaweedfs -o wide
kubectl get storageclass
kubectl get pv,pvc -A
kubectl get events -A --field-selector reason=FreeDiskSpaceFailed --sort-by=.lastTimestamp
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="DiskPressure")]}{.status}{"\t"}{.message}{end}{"\n"}{end}'
kubectl top nodes
```

Use Grafana/Loki for historical context:

- Metrics: Grafana dashboards backed by VictoriaMetrics
- Logs: `{cluster="k3s-homelab"}` and journal logs with `{job="journal"}`

## FreeDiskSpaceFailed Events

`FreeDiskSpaceFailed` is emitted by kubelet image garbage collection when kubelet needs to reclaim image filesystem space but finds too little eligible image data to delete. Treat it as a node disk pressure signal, not as proof that container images are the largest consumer.

Check the affected node:

```bash
/usr/bin/ssh -F /dev/null 192.168.1.X "df -h / /var/lib/rancher/k3s /data 2>/dev/null || df -h /"
/usr/bin/ssh -F /dev/null 192.168.1.X "sudo du -xh -d1 /data /var/lib/rancher /var/log 2>/dev/null | sort -h"
kubectl describe node <node>
```

When working directly on Hestia, local `sudo` is available and avoids SSH:

```bash
df -h / /var/lib/rancher/k3s /var/lib/kubelet /var/log /home
sudo du -xhd1 / /var/lib
kubectl get --raw /api/v1/nodes/hestia/proxy/stats/summary | \
  jq '{node: .node.nodeName, fs: .node.fs, runtime: .node.runtime}'
```

Do not assume image data is the largest consumer. The GitLab runner currently
uses the `*-nocow` host paths declared under
`infrastructure/shared-services/gitlab-runner/`. If old non-`nocow` paths such
as `/var/lib/ci-cache` or `/var/lib/ci-containers` are large, remove them only
after verifying that no live pod or manifest still references them:

```bash
rg -n '/var/lib/ci-(cache|containers)([^-]|$)' infrastructure docs
kubectl get pods -A -o json | jq -r '
  .items[] | .metadata.namespace + "/" + .metadata.name as $pod |
  (.spec.volumes // [])[]? | select(.hostPath) |
  [$pod, .name, .hostPath.path] | @tsv
' | rg '/var/lib/ci-(cache|containers)(\s|$)'
sudo findmnt -R /var/lib/ci-cache /var/lib/ci-containers
```

If `DiskPressure=False` and `df` has recovered, recent events may only be historical. Re-check after the next kubelet image GC interval before taking more action.

## CI runner acquisition and scheduler headroom

Runner managers admit **one amd64 job and one arm64 job** in total across
all their registrations. Native and generic ARM lanes share the same one-job
acquisition bound; generic jobs remain available on both architectures. Hard
cross-pool one-CI-job-per-node anti-affinity and architecture-only selectors
remain in force; no runner job is pinned to a hostname.

The idle request-headroom snapshot in
`scripts/fixtures/gitlab-runner-architecture-pools.json` records CPU and memory
for each node together. Nyx has 2530m CPU but only 7.83203125Mi memory headroom
with the GitLab webservice/Sidekiq reservations, so it is not a usable ARM slot.
Heracles fits the known ARM job envelopes. The validator counts nodes fitting
**both** dimensions for every lane, including helper, injected/declared services,
conservative manager overhead and placement margins. This is a static capacity
contract, not a dynamic admission controller or a guarantee for larger service
sets or Kubedock child Pods. Re-measure before increasing acquisition; do not
substitute job deadline extensions or reduced resource safeguards.

The official Runner image pin in
`infrastructure/shared-services/gitlab-runner/kustomization.yaml` includes the
[empty Pod resources QoS fix](https://gitlab.com/gitlab-org/gitlab-runner/-/work_items/39671).
With Pod-level requests/limits unset, Runner must omit `spec.resources` rather
than send `{}`. On Kubernetes with PodLevelResources enabled, verify new job
Pods are `Burstable`, not `BestEffort`, and their parent cgroup CPU weight is
non-minimal. Keep the existing container requests/limits and admission bounds;
CPU requests must provide sharing weight without adding CPU quotas.

All lanes leave `helper_image` unset so Runner selects its version-coupled native
helper for the job's architecture selector, not the manager Pod's architecture.
Do not restore a static helper override: the helper's internal API is
[strictly coupled to Runner](https://docs.gitlab.com/runner/configuration/advanced-configuration/#helper-image).
Generic/services lanes retain their existing `gitlab-runner-helper-pull` pull secret.

For a manager configuration rollout, pause the actual existing registrations
and verify zero active CI jobs before reconciliation. The shared generator
change affects both managers; `shutdown_timeout = 0` and the 30-second Pod grace
are not an active-job drain guarantee. After verifying both generated configs,
restore each registration's prior pause/tag/untagged state. Validate locally with
`uv --no-config run --script scripts/test_gitlab_runner_config.py` and
`python3 scripts/validate_gitlab_runner_templates.py`.

## Hestia CI cache and workspace retention

### Runner2 acquisition admission and independent restoration

The hourly minute47 unprivileged `ci-maintenance/hestia-ci-maintenance-admission` Job pauses
Runner2 only after a fresh independent-recovery heartbeat and durable named-CAS
pause intent. Daily build-store GC uses the same protocol through unprivileged
`ci-maintenance/hestia-ci-store-gc-admission` at 04:16 UTC, with an explicit
60-second offset to the native 04:17 UTC worker slot. Both controls reuse the
same admission service account and credential; workers never receive that credential.
A preexisting pause is preserved with zero writes. Accepted work
drains naturally for up to 20 minutes; no accepted job cancellation or manager
signal is used. Runner2 jobs are queried with GitLab's supported scalar status
filter for all nine nonterminal statuses: created, waiting_for_resource, preparing,
waiting_for_callback, pending, manual, scheduled, then running (including native
prepare), then canceling. Idle requires complete pagination for every filter,
bounded to 100 pages each; missing/invalid pagination or ignored filters refuse.
Completed job history is not scanned. The complete CI Pod snapshot must also show
Hestia idle: Running/Pending jobs positively assigned to heracles/nyx are exempt
because their hostPaths are node-local. Unassigned/Hestia/unknown-node active jobs,
terminating jobs and unknown phases still block; ARM Runner3 is not paused daily.

The privileged worker must win ADMITTED-to-CLAIMED for its exact native scheduled
Job and Pod UID, and checks the current claim/deadline before every candidate.
Its original 30-minute Job deadline is unchanged: draining consumes that budget.
All old mount/open/device/snapshot/API guards remain, including immediately before
the single UV-owner-native pressure backstop described below.

The independent minutely `ci-maintenance/hestia-ci-maintenance-recovery` Job has a 45-second
execution / 50-second native deadline. It CAS-seals future claims, then requires
exact terminal Pod and terminated-container evidence for the coordinator, any
claimed worker, and a prior restoration holder before baseline restoration.
Unclaimed workers cannot pass a sealed CAS and need not retire first. FailureTarget,
deletion, deadline expiry, missing Pods and NotReady nodes are not retirement proof.
Retain recovery history (90 successes and failures) and do not add a short TTL.
The next operation also waits for the previous restoration holder to retire.

State is deliberately **metadata-only in Git** (`ssa: Merge`, prune disabled).
Before activation the operator must qualify Flux field ownership, create dynamic
`data["state.json"]` explicitly using schema1, the exact ConfigMap UID, current
`policy_hash()` from the mounted two-file policy bundle, runner2, heartbeat0,
phaseIDLE, operationnull and gc_holdernull. There is no automatic missing-state bootstrap or
baseline-false default. A policy rollout requires a closed, reconciled operation
and explicit operator migration of the policy identity; never reset a live latch.
Controls alone mount the separately provisioned immutable token Secret read-only;
no Secret API permissions are granted. Token rotation must update the declared
expiry bound and requalify the closed policy identity before expiry.

`Hestia CI Maintenance Recovery Unhealthy` is a **warning**, routed by the existing
notify-only policy. It detects retained failed controller/worker Jobs and missing
or stale independent successful runs (180 seconds), including credential/API errors.
The in-state heartbeat refuses new pauses after150 seconds. At45 minutes an
unclosed operation latches ALERT; ALERT refuses new cleanup/pauses and recovery
Jobs fail visibly. An HTTP PUT timeout or crash with an unacknowledged durable
write intent is remote-effect-unknown: latch ALERT, do not issue speculative PUTs.
A readback alone cannot rule out a delayed write. The operator must establish
remote request quiescence, exact owner retirement and actual Runner2 baseline,
then explicitly reconcile the same state. Never delete the ConfigMap to silence
the warning. Ordinary acknowledged pause plus coordinator failure restores through
the independent Job; failed cleanup remains `cleanup-failed` even after restoration.
Native metric selectors, warning delivery and scheduled failure behavior must be
qualified by the release owner before enabling effects; fixtures are not that proof.

Two separate GitOps CronJobs own regenerable CI storage:

- `ci-maintenance-worker/hestia-ci-store-gc` runs at 04:17 UTC for the existing Podman image store;
  its scope and 168-hour image/container policy are unchanged. After the single
  shared GC claim, it runs the same age-bounded container, validated external-container,
  and image cleanup for both `overlay` and `vfs`, logging the selected driver.
  Overlay keeps its persistent libpod metadata; VFS uses Podman's native
  `--transient-store` with `/run/ci-containers-prune/vfs` and `/tmp/libpod-vfs`
  scratch so it does not open the overlay libpod database. Both still target only
  `/var/lib/ci-containers-nocow/storage`; there is no recurring no-age retirement.
  Scheduled GC requires exact native Job/Pod/policy identity and the daily slot's
  one-shot ADMITTED-to-CLAIMED CAS, atomically recording the shared named ConfigMap's
  single `gc_holder={identity,claimed_at}` slot. Missing, late, sealed or wrong-slot
  control admission never falls back to manual GC. While awaiting a grant, GC
  continues the complete Pod API consumer gate and refuses/releases the node if
  accepted CI materializes, including Pending CI. Waiting ends at the logical
  slot's 20-minute drain boundary, never after a restored/sealed operation.
  A terminal refused/unclaimed worker permits prompt controller closure rather
  than holding acquisition until the cleanup deadline. The native 1800-second
  worker and 1380-second control deadlines and recovery horizons are unchanged.
  Unowned native manual Jobs remain supported only in a quiet IDLE/DONE window,
  with the existing durable `gc_holder` CAS and complete API gate before effects.
  Coordinator admission and Runner2 restoration retain this slot until exact
  Pod/Job UID and all-container terminal proof; missing or replaced Pods never
  clear it. Unretired GC claims latch ALERT after 45 minutes even in IDLE/DONE.
  GC has only named state get/update and Pod/Job observation, never credentials.
- `ci-maintenance-worker/hestia-ci-cache-retention` runs hourly at minute 47 UTC on Hestia. It mounts only
  `/var/lib/ci-builds-nocow` and `/var/lib/ci-cache-nocow` writable, never the
  image store, Docker, k3s/containerd, PVCs, or application data.

Retention removes idle direct-child workspace directories after **7 days** and
regenerable direct-child cache namespaces after **30 days**. Age is the newest
descendant **regular file mtime**, not the namespace/parent directory mtime.
Nested workspace symlinks also contribute their own newest mtime/ctime, never
their target's age; empty directory trees use their newest directory mtime
conservatively. At
**67% or more filesystem usage**, the capacity backstop removes idle workspaces
first, then oldest cache namespaces, until usage is **65% or less**. Usage is
checked after age cleanup. Both root directories and their ownership remain
intact. Unexpected non-directory entries and runtime-store names are protected.

The earlier trigger and hourly cadence proactively preserve headroom, but cadence
alone does not guarantee a reserve: active consumers and safety guards can prevent
cleanup, and filesystem usage can grow between runs.

The worker uses the qualified official UV 0.11.26/Python 3.14 image pinned to
`ghcr.io/astral-sh/uv@sha256:d21c2dd538d409d050027f67cd09f0b84882cf59072cf77720b15e21f3fe6af5`
and direct `/usr/local/bin/python3 -B /policy/cache-retention.py`. Store-GC keeps
its separate Podman image and policy unchanged. The worker retains its host
privileges and writable host roots; its dedicated service account and policy bundle live only in the
GitOps-owned privileged-PSA `ci-maintenance-worker` namespace. Its cross-namespace
bindings allow listing CI Pods and get/update only the named
`ci-maintenance/hestia-ci-maintenance-state`; its local observer can list Pods and
read Jobs for identity. It has no GitLab credential. Controls, state and the future
token Secret remain in restricted `ci-maintenance`. Controls only observe Pods/Jobs
in all three namespaces and update named state; no Secret API or workload writes.
The existing CI role is unchanged and has no binding into either new namespace:
its create/exec authority in `ci` cannot select or exec the worker/control SAs
there. Before replacement credentials or activation, qualify native negative SARs
for state/Secret and Pod create/exec in both namespaces, and read back actual Pod
service accounts, namespaces and policy bundles. Source fixtures are not live proof.
This closes the direct Kubernetes API/SA-selection/exec path, not the preexisting
host trust boundary: malicious privileged node-root CI remains outside this claim.

CI job templates, the worker and store-GC all require hard hostname anti-affinity
over exactly `ci` and `ci-maintenance-worker`, retaining the same CI-label selector.
Before merge/Flux reconciliation, the release owner must pause new acquisition on
both Runner2 and Runner3 and let every accepted job finish naturally, then perform
the routine GitOps manager template rollout. Read back effective generated config
and new Pod affinity before restoring each prior acquisition baseline and running
exact-main CI. No SIGTERM/restart of a manager with accepted work, CI cancellation,
capacity/deadline change or imperative manager workaround is authorized.

Store-GC retains its CI namespace fence; cache retention independently validates
complete CI and worker-namespace Pod lists before its combined UID/conflict fence.
The maintenance
Pod's UID/labels/Hestia assignment must match and its phase must be Running.
Hard CI-label hostname anti-affinity blocks new CI scheduling on Hestia. Other
Running or Pending CI Pods block cleanup unless positively assigned to the known
remote nodes `heracles` or `nyx`. Unassigned Pods, unknown nodes or phases,
terminating CI Pods (including remote ones), invalid identities, duplicate UIDs,
and incomplete or malformed lists fail closed. Nonterminating Failed/Succeeded
Pods remain nonactive. Only this maintenance Pod's initial Pending observation is
retried (15 fresh observations, 2 seconds apart); every observation checks for
conflicts again. The cache-retention API fence is checked before each deletion.

This node-local exemption relies on the current local XFS CI hostPaths and
Kubedock **0.20.3** without a custom `POD_TEMPLATE`: child Pods use an empty
template, with folders copied one-way into `emptyDir` and files via ConfigMaps,
not shared mounts of the parent job's hostPaths. A child on another node cannot
write Hestia's CI hostPaths through those copies. This is a current architecture
property, not hostile-workload/RBAC isolation. Requalify both gates before changing
the node inventory, CI storage sharing, Kubedock version, child-Pod templates or
volume/copy behavior; do not extend the exemption to an unknown node by default.

Read-only hostPath `/proc` at `/host/proc` replaces the former hostPID view for
host FD/cwd/mount inspection by **device/inode**, so
bind-mount/path aliases do not hide local consumers. Root and direct-child
candidate symlinks, all symlinks inside cache namespaces, special entries,
cross-filesystem trees, and descendant mounts (including same-device bind
mounts across visible process mount namespaces) protect the entire candidate.
Only nested symlinks inside workspace directories are unlink-only leaves:
absolute, relative, dangling, cyclic, file and directory links are never followed
or opened, and their targets are never deleted. Their own identity and metadata
participate in the pre-deletion proof and leaf-change checks. Generic deletion still denies cache links. The fixed `uv` child is always excluded
from Python age and pressure deletion, even without links. Bun, Cargo, installed
tools and managed Python are protected, not newly reclaimable classes.
Unreadable process/mount metadata, malformed mount records, and inaccessible
mount roots on the cleanup filesystem fail closed. Mount roots are skipped before
resolution only when validated kernel device identities prove they belong to a
different filesystem. Deletion rechecks the tree and uses
no-follow, FD-relative traversal. Do not start ad-hoc host consumers concurrently:
the scheduler fence covers CI, not arbitrary host processes opening files after
the final inspection. Protected entries are logged, never force-removed. If the
capacity target cannot be reached in scope, the job fails rather than widening
cleanup. Dry runs report candidates but cannot claim a post-deletion capacity.

Only if ordinary retention triggered at 67% and still cannot reach 65%, the worker
may run **one** `/usr/local/bin/uv --no-config --offline --no-python-downloads cache clean
--cache-dir /var/lib/ci-cache-nocow/uv`, never `--force`, prune/retry, or Python
fallback. The Runner mapping `UV_CACHE_DIR=/ci-cache/uv` must still resolve to this
exact host child. Cache-only custody, ordinary no-follow ancestry, same device,
validated CACHEDIR.TAG, cache-generation-only top-level names, complete mount/open
guards and an unchanged streamed metadata fingerprint are required. UV proof alone
admits link leaves without following targets; it grants no generic deletion rights.
The qualified UV 0.11.26 cache buckets are archive, binaries, builds, environments,
flat-index, git, interpreter, osv, python, sdists, simple and wheels, each with a
`-vN` generation suffix (coexisting generations allowed). `python-vN` caches Python
downloads and `binaries-vN` caches tool downloads: neither admits installed managed
Python or tools. Plain `python`/`tools`, unknown buckets, root links and specials
remain refused; protected sibling namespaces are unchanged.
The binary SHA/version are checked against the qualified executor. The subprocess
uses a minimal explicit environment, neutral cwd and closed stdin, inherited logs,
a 330-second wait and bounded kill/reap on failure. UV's default native locks remain.
Native clean may remove the cache root; only normal UV operations recreate it.
Success is measured from actual filesystem use, not UV's hardlink byte count:
65% maximum and at least **38,857,516,474 available bytes** are required after a
pressure run. Insufficient reclaim, nonzero exit, timeout or reserve shortfall fail
without another class or cleanup attempt.

The worker now has private PID namespaces (`hostPID: false`,
`shareProcessNamespace: false`), and Python must be container PID1 before spawning
UV. Namespace-init teardown kills/waits for namespace children before init exits;
the existing all-container terminal recovery fence therefore includes the native
child boundary. If bounded reap cannot prove retirement, the worker fails and
relies on that kernel containment; it does not claim child retirement. No new
capability, runtime mount or sidecar is added. This is path-based native deletion
under maintained scheduler/claimed-pause writer exclusion, not descriptor-relative
UV removal or malicious-host-root race resistance. Actual host-proc visibility,
PID-namespace retirement and default-lock behavior in this exact image require
native release qualification. Before activation also verify effective cache-only
custody/overrides, external cache-symlink dependents, root recreation ownership and
SELinux, and the unchanged pause/drain/restoration gates. The administrator token
remains revoked/absent until the release owner completes those checks.

```bash
kubectl get cronjobs,jobs -n ci-maintenance-worker -l app=hestia-ci-cache-retention
kubectl logs -n ci-maintenance-worker -l app=hestia-ci-cache-retention --tail=100
python3 scripts/test_hestia_ci_cache_retention.py
```

The ConfigMap helper defaults to a dry run; the CronJob explicitly supplies
`--execute`. A one-off dry-run Pod must retain the same service account,
downward-API identity, labels, anti-affinity, private PID namespace and narrow mounts, omitting
only `--execute`. There are no production path overrides or force/bypass flags.
Use the approved retention owner rather than raw recursive deletion.

## SeaweedFS Sideloaded Server Images

The `chrislusf/seaweedfs:<base>-nebm-<commit>` server image is sideload-only:
do not push it to `registry.brmartin.co.uk`, because the registry depends on
SeaweedFS. If kubelet image GC removes a sideloaded server image from a node,
pods can enter `ImagePullBackOff` even though desired state is correct.

Build from the hard fork's current master, sideload all node architectures, then
bump the tag in `infrastructure/storage/seaweedfs/core/kustomization.yaml`:

```bash
git clone https://git.brmartin.co.uk/ben/seaweedfs.git /tmp/seaweedfs
git -C /tmp/seaweedfs fetch origin master
git -C /tmp/seaweedfs checkout origin/master
SEAWEEDFS_COMMIT=$(git -C /tmp/seaweedfs rev-parse --short HEAD)

make -C drivers/seaweedfs-server tars \
  SEAWEEDFS_SOURCE=/tmp/seaweedfs \
  SEAWEEDFS_COMMIT=$SEAWEEDFS_COMMIT

make -C drivers/seaweedfs-server sideload \
  SEAWEEDFS_SOURCE=/tmp/seaweedfs \
  SEAWEEDFS_COMMIT=$SEAWEEDFS_COMMIT
```

Before rolling `seaweedfs-master`, restore a failed master pod first when
possible so the rollout starts from 3/3 quorum. After the rollout, verify:

```bash
kubectl get statefulsets,deployments,daemonsets -n default -l app=seaweedfs -o wide
kubectl exec -n default seaweedfs-master-0 -- /usr/bin/weed version
kubectl exec -n default seaweedfs-master-1 -- /usr/bin/weed version
```

## SeaweedFS PVC Issues

### PVC Pending

```bash
kubectl describe pvc <pvc-name> -n <namespace>
kubectl get pods -n default -l app=seaweedfs -o wide
kubectl logs -n default deploy/seaweedfs-csi-controller -c csi-seaweedfs
```

Common causes:

- `seaweedfs-csi-controller` is not ready
- `seaweedfs-filer` is unreachable
- The StorageClass name is wrong; use `seaweedfs` for RWX filer-backed PVCs

### Mounted Pod Reports Stale FUSE Mount

SeaweedFS CSI uses FUSE mounts. An unexpected `seaweedfs-mount` crash, a
forced old-pod deletion during takeover, or a previously broken mount can leave
existing pods with `Transport endpoint is not connected`. The current
`seaweedfs-mount` DaemonSet replaces one node at a time (`maxSurge: 0`,
`maxUnavailable: 1`) because the process owns a node-local Unix socket and live
FUSE state. A replacement may require the consumer recycler to recreate stale
consumer pods; check application readiness after the storage rollout.

```bash
kubectl get pods -A -o wide | grep <node>
kubectl delete pod -n <namespace> <pod-name>
```

New pods remount cleanly through kubelet. If a registry-backed image pull is blocked by stale registry storage, cordon the affected node, reschedule the registry, then uncordon.

If a routine `seaweedfs-mount` rollout looks stuck, inspect the replacement pod
before deleting anything:

```bash
kubectl get pods -n default -l app=seaweedfs,component=seaweedfs-mount -o wide
kubectl describe pod -n default <new-mount-pod>
kubectl logs -n default <new-mount-pod>
```

Do not force-delete a healthy mount pod to clear a stalled rollout. Inspect the
DaemonSet's current update strategy and replacement readiness first. With the
current non-surge strategy, resource troubleshooting concerns the replacement
pod's normal requests, not capacity for an extra mount pod on each node.

Apps that both mount SeaweedFS PVCs and pull from the internal GitLab registry
can now declare a recycler rollout smoke with pod-template annotations under
`seaweedfs.csi.brmartin.co.uk/`. During a `seaweedfs-mount` restart wave, the
recycler evicts ungated consumers first, then waits for each gated pod's HTTP
smoke to pass before cycling it. `iris` uses this to hold its recycler-driven
restart until GitLab JWT auth is back at `/jwt/auth`, preventing transient
`ErrImagePull` / `ImagePullBackOff` windows while GitLab web/workhorse recycle.

### SeaweedFS Volume or Filer Health

```bash
kubectl exec -n default deploy/seaweedfs-s3 -- weed shell -master=seaweedfs-master:9333 -exec=cluster.check
kubectl logs -n default -l app=seaweedfs,component=volume --tail=100
kubectl logs -n default -l app=seaweedfs,component=filer --tail=100
```

Volume servers run on Heracles and Nyx with host data at `/data/seaweedfs`. The filer metadata backend is Postgres-backed through the `seaweedfs-filer` configuration.

### SeaweedFS Read-Only Mail Volumes

Maildir delete incidents can leave single-replica SeaweedFS volumes latched
read-only. The first response is evidence capture, not forcing the volume
writable again.

Capture the current state before mutating:

```bash
kubectl exec -n default deploy/seaweedfs-s3 -- weed shell -master=seaweedfs-master:9333 -exec='volume.list'
kubectl logs -n default -l app=seaweedfs,component=filer --since=1h | rg 'max retry attempts \(10\) reached|read only'
kubectl logs -n default -l app=seaweedfs,component=seaweedfs-mount --since=1h | rg 'metadata revision mismatch|dovecot-uidlist'
kubectl logs -n default deploy/sogo --since=1h | rg 'folderINBOX/batchDelete'
```

Tail-only corruption on a regular single-replica volume is now repaired through
the forked SeaweedFS shell command `volume.repair.tail`. Run it under the shell
lock, against the affected volume server gRPC port, with a host backup
directory:

```bash
kubectl exec -n default deploy/seaweedfs-s3 -- \
  weed shell -master=seaweedfs-master:9333 -lock=true \
  -exec='volume.repair.tail -node <volume-server-host:port> -volumeId 894,895 -apply -markWritable -backupDir /data/seaweedfs/incident-20260614-backup'
```

Use the exact volume server address shown for the affected volume in
`volume.list`; do not route the repair through the shared `seaweedfs-volume`
Service.

Guardrails:

- The command refuses non-tail corruption; do not mark a volume writable if the
  post-repair scrub is not clean.
- The volume must already be read-only before `-apply`; the server unmounts,
  backs up, truncates, remounts, and re-scrubs before it can mark the volume
  writable.
- Back up `.dat`, `.idx`, and `.vif` first. For Heracles and Nyx the live host
  path is `/data/seaweedfs`.

Resume checks after the repair:

```bash
kubectl exec -n default deploy/seaweedfs-s3 -- weed shell -master=seaweedfs-master:9333 -exec='volume.list'
kubectl logs -n default -l app=seaweedfs,component=filer --since=15m | rg 'max retry attempts \(10\) reached|read only'
kubectl logs -n default deploy/sogo --since=30m | rg 'folderINBOX/batchDelete'
```

Recovery is not done until a canary hard delete from `Trash` succeeds, filer
delete retry exhaustion stays absent, and the original mail delete window is
replayed.

### SeaweedFS Volume Rollout Smoke Check

A `seaweedfs-volume` replacement can stale the volume-server routing cached by
healthy `seaweedfs-mount` daemons on every node, not only the node that hosts
the replaced volume pod. The consumer recycler now watches cluster-wide volume
pod replacements and triggers an in-place routing refresh through the local
mount service on each node after the replacement pod becomes Ready. This path
must not restart `seaweedfs-mount` or recycle application pods during a routine
volume rollout. The disruptive mount-restart path remains reserved for actual
mount-daemon failure or stale FUSE repair.

Check the rollout in this order:

```bash
kubectl get pods -n default -l app=seaweedfs,component=volume -o wide
kubectl logs -n default -l app.kubernetes.io/name=seaweedfs-consumer-recycler --since=15m
kubectl logs -n default -l app=seaweedfs,component=seaweedfs-mount --since=15m
```

Healthy rollout signals:

- each replacement `seaweedfs-volume` pod is `Running` and `Ready`
- recycler logs show `volume server replacement detected`, then
  `refreshed local mount routing after volume replacement`
- Kubernetes events on the replaced volume pod show
  `VolumeRefreshStarted` followed by `VolumeRefreshSucceeded`
- mount logs do not keep repeating `retry reading in` or `dial tcp ... i/o timeout`
  against old volume-pod IPs after the refresh has fired
- there are no rollout-path `mount daemon restart detected` logs and no
  recycler-triggered application evictions

Failure signals:

- recycler events show `VolumeRefreshFailed`
- recycler metrics increment `seaweedfs_recycler_volume_refreshes_total{result="failed"}`
- stale-IP mount retries continue after the replacement volume pod is Ready

Treat a refresh failure as a blocked storage rollout, not as permission to
restart `seaweedfs-mount` or arbitrary RWX consumers automatically. The
disruptive remount-and-recycle path is emergency repair, not routine rollout
behavior.

## local-path Issues

`local-path` and `local-path-retain` are node-local. Check the scheduled node before deleting or rescheduling workloads:

```bash
kubectl get pod <pod-name> -n <namespace> -o wide
kubectl describe pvc <pvc-name> -n <namespace>
/usr/bin/ssh -F /dev/null <node-ip> "sudo du -xh -d2 /var/lib/rancher/k3s/storage 2>/dev/null | sort -h | tail -40"
```

Do not delete retained local-path directories unless the owning PV/PVC has been intentionally retired.

## Retired Gluster/Ganesha Guard

Use the guard script before claiming retired storage has reappeared:

```bash
scripts/retire-gluster-ganesha.sh --node hestia
scripts/retire-gluster-ganesha.sh --node heracles
scripts/retire-gluster-ganesha.sh --node nyx
```

The script verifies that:

- `glusterfs-nfs` is absent
- no PV/PVC uses `glusterfs-nfs`
- no live pod hostPath references `/data/glusterfs` or `/storage`
- Gluster/Ganesha units, processes, mounts, and storage listener ports are inactive

Historical repair procedures are archived in:

- `docs/archived/glusterfs-architecture.md`
- `docs/archived/nfs-ganesha-migration.md`
- `docs/archived/gluster-ganesha-storage-troubleshooting.md`
