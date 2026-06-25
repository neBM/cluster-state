# Storage Troubleshooting

This runbook covers the current storage stack. GlusterFS and NFS-Ganesha were retired on May 30, 2026; historical notes live under `docs/archived/`.

## Current Storage Paths

| Storage | Use | Manifests |
|---------|-----|-----------|
| `seaweedfs` StorageClass | RWX PVCs and filer-backed app data | `infrastructure/storage/seaweedfs/`, app PVCs ending in `-sw` |
| SeaweedFS S3/COSI | Object buckets for backups, cache, and attachments | `infrastructure/storage/seaweedfs/cosi/` |
| `local-path` / `local-path-retain` | Node-local RWO data, especially database-heavy services | `infrastructure/storage/storage-classes/` |
| `synology-nfs-static` | Static read-only media shares | `apps/iris/`, `apps/media-centre/` |
| `/mnt/csi/backups/restic` on Hestia | Restic repository host path | `infrastructure/storage/restic-backup/` |

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
existing pods with `Transport endpoint is not connected`. Routine
`seaweedfs-mount` upgrades should now use a surge rollout and stall safely on
busy mounts rather than dropping live sessions.

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

Healthy takeover behavior is: old pod still `Ready`, new pod `Running` but not
`Ready` until `/readyz` flips green, then the DaemonSet removes the old pod. A
rollout that stalls on busy mounts is a safe block, not permission to force a
disruptive restart.

If the new pod never schedules and `kubectl describe pod` shows
`FailedScheduling` with `Insufficient memory` or `Insufficient cpu` on the
target node, the rollout budget is wrong: the mount pod request must leave room
for one extra pod on the smallest node during `maxSurge` handoff. Fix the
request in desired state rather than force-deleting the old mount pod.

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
