# SeaweedFS Bucket Audit

This note is the durable operator runbook for auditing the SeaweedFS filer
namespace under `/buckets`.

Two different resource models live there:

- `pvc-*` directories are CSI volume handles for the `seaweedfs`
  `StorageClass`.
- non-`pvc-*` directories are named S3 buckets consumed directly by
  applications.

Do not treat those two sets interchangeably. A `pvc-*` directory is audited
against live `PersistentVolume.spec.csi.volumeHandle` values; a named bucket is
audited against current manifests, live workloads, and
`docs/seaweedfs-s3-identities.md`.

As of 2026-05-07:

- `23` live `pvc-*` filer directories matched `23` `Bound` SeaweedFS PV
  handles.
- `0` orphaned live `pvc-*` directories remained after the same-day scrub.
- `8` named buckets existed.
- `7` named buckets had current consumers.
- `1` named bucket, `renovate-cache`, had no current consumer and is an
  abandoned-data candidate.

## Durable Rules

1. Do not delete a filer path just because it looks old. Prove that no live PV,
   PVC, manifest, or workload still points at it.
2. Deleting a Kubernetes PV object does not scrub the corresponding SeaweedFS
   filer path. Cleanup is a separate explicit step.
3. Treat named buckets as application data, not CSI storage. A named bucket can
   be active even when its current size is small or zero.
4. If a bucket has no current consumer, inspect its size and top-level content
   before deleting it. Small buckets can still hold data worth keeping.

## Commands

List the filer entries:

```bash
kubectl exec -n default seaweedfs-master-0 -- sh -lc \
  "printf 'fs.ls /buckets\n' | weed shell -master=seaweedfs-master:9333"
```

List the live `Bound` SeaweedFS volume handles:

```bash
kubectl get pv -o json | python3 - <<'PY'
import json
import sys

data = json.load(sys.stdin)
handles = sorted(
    item["spec"]["csi"]["volumeHandle"]
    for item in data["items"]
    if item.get("status", {}).get("phase") == "Bound"
    and item.get("spec", {}).get("storageClassName") == "seaweedfs"
    and item.get("spec", {}).get("csi", {}).get("volumeHandle")
)

for handle in handles:
    print(handle)
PY
```

Inspect a single filer path:

```bash
kubectl exec -n default seaweedfs-master-0 -- sh -lc \
  "printf 'fs.du /buckets/<name>\nfs.meta.cat /buckets/<name>\n' | weed shell -master=seaweedfs-master:9333"
```

Scrub a confirmed orphan:

```bash
kubectl exec -n default seaweedfs-master-0 -- sh -lc \
  "printf 'fs.rm -rf /buckets/<name>\n' | weed shell -master=seaweedfs-master:9333"
```

## `pvc-*` Audit Workflow

1. List `/buckets/pvc-*`.
2. Compare those names to the current set of `Bound` SeaweedFS PV
   `volumeHandle` values.
3. Any filer directory present in `/buckets` but missing from the bound-handle
   set is an orphan candidate.
4. Before deleting it, check whether it came from a recently `Released` PV and
   whether the path still contains operator-useful data.
5. If the answer is no, delete the stale PV object first if it still exists,
   then scrub the filer path explicitly.

The point-in-time 2026-05-07 cleanup of released SeaweedFS PVs is recorded in
[seaweedfs-released-pv-audit.md](seaweedfs-released-pv-audit.md).

## Named Bucket Audit Workflow

1. List all non-`pvc-*` directories under `/buckets`.
2. For each bucket, find current consumers in three places:
   - checked-in manifests under `apps/` and `infrastructure/`
   - live workload objects in the cluster
   - the current identity mapping in
     [seaweedfs-s3-identities.md](seaweedfs-s3-identities.md)
3. If a bucket has no current consumer, inspect its size and top-level keys to
   distinguish an abandoned cache from meaningful retained data.
4. Only after that classify it as either active or a cleanup candidate.

## Current Named Bucket Baseline

| Bucket | Status | Current consumer evidence |
| --- | --- | --- |
| `athenaeum-attachments` | Active | `apps/athenaeum/deployment-default-athenaeum-backend.yaml` reads `MINIO_BUCKET` and the SeaweedFS S3 endpoint from `athenaeum-secrets` |
| `gitlab-runner-cache` | Active | `infrastructure/shared-services/gitlab-runner/configmap-default-gitlab-runner-config-template-*.yaml` sets `BucketName = "gitlab-runner-cache"` for the live runner deployments |
| `langfuse` | Active | `apps/langfuse/deployment-default-langfuse-{web,worker}.yaml` enable S3 event upload to bucket `langfuse` via `langfuse-secrets` |
| `loki` | Active | `infrastructure/observability-core/loki/configmap-default-loki-config.yaml` sets `bucketnames: "loki"` for the live `StatefulSet/loki` |
| `overseerr-litestream` | Active | `apps/overseerr/configmap-default-overseerr-litestream.yaml` points Litestream at bucket `overseerr-litestream` for the live `Deployment/overseerr` |
| `plex-backup` | Active | `apps/media-centre/cronjob-default-plex-db-backup.yaml` writes rolling backups to `plex-backup`, and `apps/media-centre/deployment-default-plex.yaml` reads the same bucket for restore |
| `victoriametrics` | Active | `infrastructure/observability-core/victoriametrics/deployment-default-victoriametrics.yaml` runs `vmbackup`/`vmrestore` against bucket `victoriametrics` |
| `renovate-cache` | Abandoned-data candidate | No checked-in manifest or live workload references `renovate` or `renovate-cache`; only `default/renovate-secrets` remains. The bucket still holds about `1.2 MiB` and its last observed filer mtime was `2026-04-22T15:29:37Z`, so treat it as explicit cleanup rather than silent drift. |

## Current `renovate-cache` Evidence

The 2026-05-07 audit found:

- no `Deployment`, `StatefulSet`, `DaemonSet`, `CronJob`, `Job`, `Pod`,
  `Service`, `Ingress`, `IngressRoute`, or checked-in manifest using
  `renovate`, `renovate-secrets`, or `renovate-cache`
- one leftover live `Secret`, `default/renovate-secrets`, created on
  `2026-01-24T21:51:44Z` and still labeled `app=renovate`
- about `1.2 MiB` of filer content under `/buckets/renovate-cache`
- a top-level path of `gitlab/`, with nested project cache paths below it

That is enough to treat the bucket and secret as cleanup candidates, but not to
delete them automatically without an explicit operator decision.
