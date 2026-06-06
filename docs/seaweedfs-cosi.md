# SeaweedFS COSI Runbook

This cluster uses COSI `objectstorage.k8s.io/v1alpha1` as the desired-state
control plane for SeaweedFS S3 buckets and credentials.

The base GitOps increment installs:

- COSI CRDs and controller from `container-object-storage-interface@release-0.2`
- the SeaweedFS COSI driver `v0.3.0`
- a local `cosi-provisioner-sidecar` image pinned to upstream `v0.1.0` with a
  status-subresource fix for `BucketClaim.status.bucketReady`
- `BucketClass/seaweedfs`
- `BucketAccessClass/seaweedfs-readwrite`
- `BucketAccessClass/seaweedfs-readonly`

Production buckets are migrated one at a time. Existing workload Secrets and
manually managed SeaweedFS identities remain available as rollback boundaries
until each bucket is migrated and verified.

## Production Status

| Bucket | Status | COSI resources | Workload consumption | Verification |
|---|---|---|---|---|
| `plex-backup` | Migrated | `Bucket/plex-backup`, `BucketClaim/default/plex-backup`, `BucketAccess/default/plex-backup` | `Secret/default/plex-backup-s3` mounted as `BucketInfo` by `Deployment/plex` db-restore init and `CronJob/plex-db-backup` | Manual `plex-db-backup` job completed on 2026-05-12; scoped credentials were denied against `overseerr-litestream` |
| `victoriametrics` | Migrated | `Bucket/victoriametrics`, `BucketClaim/default/victoriametrics`, `BucketAccess/default/victoriametrics` | `Secret/default/victoriametrics-cosi-s3` mounted as `BucketInfo` by `Deployment/victoriametrics` vmrestore init and vmbackup sidecar | Restore and backup completed on 2026-05-12; scoped credentials were denied against `plex-backup` |
| `loki` | Migrated | `Bucket/loki`, `BucketClaim/default/loki`, `BucketAccess/default/loki` | `Secret/default/loki-cosi-s3` mounted as `BucketInfo` by `StatefulSet/loki` render-config init | Loki restarted with rendered COSI config on 2026-05-12 and read TSDB index files from S3; scoped credentials were denied against `plex-backup` |
| `athenaeum-attachments` | Migrated | `Bucket/athenaeum-attachments`, `BucketClaim/default/athenaeum-attachments`, `BucketAccess/default/athenaeum-attachments` | `Secret/default/athenaeum-attachments-s3` mounted as `BucketInfo` by `Deployment/athenaeum-backend` | Backend restarted healthy on 2026-05-12; scoped credentials wrote/read/deleted a smoke object and were denied against `plex-backup` |
| `gitlab-runner-cache` | Migrated | `Bucket/gitlab-runner-cache`, `BucketClaim/default/gitlab-runner-cache`, `BucketAccess/default/gitlab-runner-cache` | `Secret/default/gitlab-runner-cache-cosi-s3` mounted as `BucketInfo` by GitLab runner config-generator init containers | All runner Deployments restarted on 2026-05-12 with generated cache config; scoped credentials wrote/read/deleted a smoke object and were denied against `plex-backup` |
| `renovate-cache` | Migrated | `Bucket/renovate-cache`, `BucketClaim/default/renovate-cache`, `BucketAccess/default/renovate-cache` | `Secret/default/renovate-cache-s3` `BucketInfo` values synced into `infrastructure/renovate-runner` GitLab CI variables | Manual Renovate pipeline `2432` completed on 2026-05-12; scoped credentials wrote/read/deleted a smoke object and were denied against `plex-backup` |

## Deployment Checks

```bash
kubectl get pods -n container-object-storage-system
kubectl get bucketclasses,bucketaccessclasses
kubectl get bucketclaims,buckets,bucketaccesses -A
```

Expected base state:

- `container-object-storage-controller` is Ready
- `seaweedfs-cosi-driver` is Ready
- `BucketClass/seaweedfs` exists with `deletionPolicy: Retain`
- both SeaweedFS `BucketAccessClass` objects exist
- production workloads only change credentials after their bucket is listed as
  migrated above

## Greenfield Proof

Create a disposable claim and access grant:

```yaml
apiVersion: objectstorage.k8s.io/v1alpha1
kind: BucketClaim
metadata:
  name: cosi-greenfield
  namespace: default
spec:
  bucketClassName: seaweedfs
  protocols:
  - s3
---
apiVersion: objectstorage.k8s.io/v1alpha1
kind: BucketAccess
metadata:
  name: cosi-greenfield
  namespace: default
spec:
  bucketAccessClassName: seaweedfs-readwrite
  bucketClaimName: cosi-greenfield
  credentialsSecretName: cosi-greenfield-s3
  protocol: s3
```

Verify:

```bash
kubectl get bucketclaim,bucketaccess -n default cosi-greenfield -o yaml
kubectl get secret -n default cosi-greenfield-s3 -o jsonpath='{.data.BucketInfo}' | base64 -d
```

Mount or decode `BucketInfo`, then write, list, read, and delete a temporary
object through `http://seaweedfs-s3.default.svc.cluster.local:8333`.

`BucketClass/seaweedfs` intentionally uses `Retain`, so deleting the claim should
not delete the backing SeaweedFS bucket. Remove the retained disposable bucket
manually after testing.

## Brownfield Proof

Before migrating production data, prove that COSI can grant access to an
existing SeaweedFS bucket without recreating it.

1. Create a non-production bucket outside COSI, for example
   `cosi-brownfield`. In this cluster the direct filer path is:

   ```bash
   kubectl exec -n default seaweedfs-master-0 -- sh -lc \
     "printf 'fs.mkdir /buckets/cosi-brownfield\n' | weed shell -master=seaweedfs-master:9333"
   ```
2. Create a matching COSI `Bucket` with `existingBucketID` set to that bucket
   name:

   ```yaml
   apiVersion: objectstorage.k8s.io/v1alpha1
   kind: Bucket
   metadata:
     name: cosi-brownfield
   spec:
     bucketClassName: seaweedfs
     bucketClaim:
       name: cosi-brownfield
       namespace: default
     deletionPolicy: Retain
     driverName: seaweedfs.objectstorage.k8s.io
     existingBucketID: cosi-brownfield
     protocols:
     - s3
   ```

3. Create a `BucketClaim` that imports that `Bucket`:

   ```yaml
   apiVersion: objectstorage.k8s.io/v1alpha1
   kind: BucketClaim
   metadata:
     name: cosi-brownfield
     namespace: default
   spec:
     existingBucketName: cosi-brownfield
     protocols:
     - s3
   ```

4. Create `BucketAccess` using `seaweedfs-readwrite`, then verify the generated
   credentials can read existing data and write a temporary object.

Stop production migration if this path deletes, recreates, or fails to grant
access to the existing bucket.

## Resilience Proofs

Run these against disposable identities before touching production buckets:

```bash
kubectl rollout restart deployment/seaweedfs-s3 -n default
kubectl rollout status deployment/seaweedfs-s3 -n default --timeout=180s
kubectl rollout restart deployment/seaweedfs-cosi-driver -n container-object-storage-system
kubectl rollout status deployment/seaweedfs-cosi-driver -n container-object-storage-system --timeout=180s
```

After each restart, verify the disposable COSI credentials still work.

To test rotation, delete and recreate the disposable `BucketAccess`, then verify:

- the new Secret credentials work without restarting `seaweedfs-s3`
- the old credentials no longer work

To test backend IAM drift, remove only the disposable SeaweedFS identity from the
filer IAM config and watch whether the COSI driver recreates it from Kubernetes
state. If it does not, stop before production migration and treat that as a
driver limitation.

## Production Order

Migrate one bucket at a time:

1. `plex-backup`
2. `victoriametrics`
3. `loki`
4. `athenaeum-attachments`
5. `gitlab-runner-cache`
6. `renovate-cache`

Prefer brownfield adoption. Only copy data into a new COSI-owned bucket if
brownfield import fails in the disposable proof.

For each migrated workload, remove admin-key use from its Secret path and keep
the previous Secret available as the rollback boundary until the workload has
successfully read or written its bucket.
