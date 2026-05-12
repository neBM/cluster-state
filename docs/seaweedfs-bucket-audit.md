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
- `1` additional bound SeaweedFS handle, `/buckets`, remained outside the
  `pvc-*` comparison and is reported separately by the helper.
- `0` orphaned live `pvc-*` directories remained after the same-day scrub.
- `7` named buckets existed.
- `7` named buckets had current consumers.
- `0` named buckets remained without a current consumer after the same-day
  cleanup of `renovate-cache`.

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

Preferred audit path:

```bash
python3 scripts/audit_seaweedfs_buckets.py
```

Machine-readable output:

```bash
python3 scripts/audit_seaweedfs_buckets.py --json
```

Fail the command when orphaned PVC dirs, missing live PVC dirs, or abandoned
named buckets are present:

```bash
python3 scripts/audit_seaweedfs_buckets.py --fail-on-findings
```

Manual filer listing:

```bash
kubectl exec -n default seaweedfs-master-0 -- sh -lc \
  "printf 'fs.ls /buckets\n' | weed shell -master=seaweedfs-master:9333"
```

Manual live `Bound` SeaweedFS volume-handle listing:

```bash
python3 - <<'PY'
import json
import subprocess

data = json.loads(subprocess.check_output(["kubectl", "get", "pv", "-o", "json"]))
for item in sorted(data["items"], key=lambda entry: entry["metadata"]["name"]):
    if item.get("status", {}).get("phase") != "Bound":
        continue
    if item.get("spec", {}).get("storageClassName") != "seaweedfs":
        continue
    handle = item.get("spec", {}).get("csi", {}).get("volumeHandle")
    if handle:
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

The helper script automates those checks by:

- comparing `/buckets/pvc-*` against the live `Bound` SeaweedFS PV handles
- searching the repo for named-bucket references in `apps/`,
  `infrastructure/`, and `clusters/`
- searching live `ConfigMap`, `Secret`, `Deployment`, `StatefulSet`,
  `DaemonSet`, `CronJob`, and `Job` objects for named-bucket references
- applying explicit external-consumer references for buckets used outside
  this repo's manifests and live Kubernetes objects
- flagging any named bucket with no current repo, live, or explicit external
  consumer as an abandoned-data candidate

## Current Named Bucket Baseline

| Bucket | Status | Current consumer evidence |
| --- | --- | --- |
| `athenaeum-attachments` | Active | `apps/athenaeum/deployment-default-athenaeum-backend.yaml` reads `MINIO_BUCKET` and the SeaweedFS S3 endpoint from `athenaeum-secrets` |
| `gitlab-runner-cache` | Active | `infrastructure/shared-services/gitlab-runner/runner-base/fragments/95-cache.toml` sets `BucketName = "gitlab-runner-cache"` for all live runner overlays |
| `langfuse` | Active | `apps/langfuse/deployment-default-langfuse-{web,worker}.yaml` enable S3 event upload to bucket `langfuse` via `langfuse-secrets` |
| `loki` | Active | `infrastructure/observability-core/loki/configmap-default-loki-config.yaml` sets `bucketnames: "loki"` for the live `StatefulSet/loki` |
| `overseerr-litestream` | Active | COSI `BucketAccess/default/overseerr-litestream` creates `overseerr-litestream-s3`; `apps/overseerr/deployment-default-overseerr.yaml` mounts `BucketInfo` for Litestream |
| `plex-backup` | Active | `apps/media-centre/cronjob-default-plex-db-backup.yaml` writes rolling backups to `plex-backup`, and `apps/media-centre/deployment-default-plex.yaml` reads the same bucket for restore |
| `renovate-cache` | Active | `infrastructure/renovate-runner` GitLab CI config sets `RENOVATE_REPOSITORY_CACHE_TYPE=s3://renovate-cache`; credentials live in protected GitLab CI variables |
| `victoriametrics` | Active | COSI `BucketAccess/default/victoriametrics` creates `victoriametrics-cosi-s3`; `infrastructure/observability-core/victoriametrics/deployment-default-victoriametrics.yaml` mounts `BucketInfo` for `vmbackup`/`vmrestore` |

## Removed Named Buckets

The 2026-05-07 audit and cleanup pass incorrectly removed
`renovate-cache` because its consumer is a GitLab CI project outside this
repo and not a Kubernetes workload. The bucket was recreated on 2026-05-08
with owner `renovate`; keep it in the active baseline.
