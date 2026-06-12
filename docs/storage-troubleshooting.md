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

If `DiskPressure=False` and `df` has recovered, recent events may only be historical. Re-check after the next kubelet image GC interval before taking more action.

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

SeaweedFS CSI uses FUSE mounts. A rollout of `seaweedfs-csi-node` or `seaweedfs-mount` can leave existing pods with `Transport endpoint is not connected`.

```bash
kubectl get pods -A -o wide | grep <node>
kubectl delete pod -n <namespace> <pod-name>
```

New pods remount cleanly through kubelet. If a registry-backed image pull is blocked by stale registry storage, cordon the affected node, reschedule the registry, then uncordon.

### SeaweedFS Volume or Filer Health

```bash
kubectl exec -n default deploy/seaweedfs-s3 -- weed shell -master=seaweedfs-master:9333 -exec=cluster.check
kubectl logs -n default -l app=seaweedfs,component=volume --tail=100
kubectl logs -n default -l app=seaweedfs,component=filer --tail=100
```

Volume servers run on Heracles and Nyx with host data at `/data/seaweedfs`. The filer metadata backend is Postgres-backed through the `seaweedfs-filer` configuration.

### SeaweedFS Volume Rollout Smoke Check

A `seaweedfs-volume` replacement can stale the volume-server routing cached by
healthy `seaweedfs-mount` daemons on every node, not only the node that hosts
the replaced volume pod. The consumer recycler now watches cluster-wide volume
pod replacements and should cycle SeaweedFS-backed consumers on each node after
the replacement pod becomes Ready.

Check the rollout in this order:

```bash
kubectl get pods -n default -l app=seaweedfs,component=volume -o wide
kubectl logs -n default -l app.kubernetes.io/name=seaweedfs-consumer-recycler --since=15m
kubectl logs -n default -l app=seaweedfs,component=seaweedfs-mount --since=15m
```

Healthy rollout signals:

- each replacement `seaweedfs-volume` pod is `Running` and `Ready`
- recycler logs show `volume server replacement detected` on each node and
  `cycling consumer pods` for local SeaweedFS consumers
- mount logs do not keep repeating `retry reading in` or `dial tcp ... i/o timeout`
  against old volume-pod IPs after the recycler has fired

If recycler fanout did not happen, expect user-facing latency rather than
`Transport endpoint is not connected`: mail and other SeaweedFS-backed services
can hang on cold reads while `seaweedfs-mount` retries stale remote volume
addresses.

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
