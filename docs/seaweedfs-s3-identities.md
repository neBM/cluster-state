# SeaweedFS S3 Identity Management

Per-service S3 identities, scoped to individual buckets. The shared
`admin` identity is reserved for operator use only (bucket creation,
emergency access); all workloads use scoped identities.

SeaweedFS S3 is the live object-storage endpoint for the cluster at
`http://seaweedfs-s3.default.svc.cluster.local:8333`.

Some consumers still use legacy secret key names such as
`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, and in Athenaeum also
`MINIO_URL` / `MINIO_BUCKET`. Those names are compatibility baggage from
the MinIO era; they do not imply a MinIO backend.

COSI-managed consumers use `objectstorage.k8s.io` `Bucket`,
`BucketClaim`, and `BucketAccess` resources. Their generated Secret
contains a `BucketInfo` JSON document with the bucket name, endpoint,
region, and scoped S3 credentials.

For legacy consumers, there is no active External Secrets controller in
the current cluster. Those secrets are plain Kubernetes `Secret` objects,
so manual `kubectl patch` or recreate operations are the durable repair
and rotation path until the consumer is migrated to COSI.

Avoid `kubectl apply` for these secrets. It stores the secret payload in
the `kubectl.kubernetes.io/last-applied-configuration` annotation,
which is both misleading and an unnecessary plaintext copy of the data.

For filer `/buckets` audit rules, `pvc-*` cleanup boundaries, and current
named-bucket cleanup candidates, see
[seaweedfs-bucket-audit.md](seaweedfs-bucket-audit.md).

## Identity → bucket → secret mapping

| Identity | Bucket | K8s Secret | Key names | Consumers |
|---|---|---|---|---|
| COSI `BucketAccess/default/loki` | `loki` | `loki-cosi-s3` | `BucketInfo.spec.secretS3` | StatefulSet/loki render-config init |
| COSI `BucketAccess/default/victoriametrics` | `victoriametrics` | `victoriametrics-cosi-s3` | `BucketInfo.spec.secretS3` | Deployment/victoriametrics vmrestore init and vmbackup sidecar |
| COSI `BucketAccess/default/plex-backup` | `plex-backup` | `plex-backup-s3` | `BucketInfo.spec.secretS3` | Deployment/plex (db-restore init), CronJob/plex-db-backup |
| COSI `BucketAccess/default/athenaeum-attachments` | `athenaeum-attachments` | `athenaeum-attachments-s3` | `BucketInfo.spec.secretS3` | Deployment/athenaeum-backend |
| COSI `BucketAccess/default/langfuse` | `langfuse` | `langfuse-s3` | `BucketInfo.spec.secretS3` | Deployments langfuse-{web,worker} |
| COSI `BucketAccess/default/gitlab-runner-cache` | `gitlab-runner-cache` | `gitlab-runner-cache-cosi-s3` | `BucketInfo.spec.secretS3` | Deployments gitlab-runner-{amd64,any,arm64,services} config-generator init |
| COSI `BucketAccess/default/renovate-cache` | `renovate-cache` | `renovate-cache-s3` synced into GitLab CI variables in `infrastructure/renovate-runner` | `BucketInfo.spec.secretS3` -> `S3_ACCESS_KEY`, `S3_SECRET_KEY` | Scheduled Renovate runner job |
| COSI `BucketAccess/default/overseerr-litestream` | `overseerr-litestream` | `overseerr-litestream-s3` | `BucketInfo.spec.secretS3` | Deployment/overseerr Litestream containers |
| `admin` | *(unscoped, full Admin)* | *(not in any workload secret)* | — | Operator use only |

All scoped identities have actions `Read,Write,List,Tagging` on their
bucket only. `admin` has the additional `Admin` action cluster-wide.

Athenaeum still uses `MINIO_*` process environment names internally, but
`Deployment/athenaeum-backend` derives them from the mounted COSI `BucketInfo`
at container start.

Renovate runs in an external GitLab CI project rather than as a Kubernetes
workload. COSI owns the backend SeaweedFS bucket identity, and the GitLab CI
variables are the compatibility boundary. On rotation, sync values from
`Secret/default/renovate-cache-s3` `BucketInfo.spec.secretS3` into that project.

## Managing identities via `weed shell`

Open a shell against a master pod:

```bash
kubectl -n default exec -it seaweedfs-master-0 -- sh -c 'weed shell -master=seaweedfs-master:9333'
```

### List all identities

```
s3.configure
```

Prints the full JSON identity config.

### Create or update an identity

```
s3.configure -apply -user <name> -access_key <key> -secret_key <secret> \
  -buckets <bucket1,bucket2> -actions Read,Write,List,Tagging
```

`-apply` is required to persist. Omit `-buckets` for cluster-wide
access (avoid except for `admin`). Re-running with the same `-user`
replaces that identity's credentials and action scope.

### Delete an identity

```
s3.configure -delete -user <name>
```

### Inspect a single identity

```
s3.configure -user <name>
```

## Legacy rotation procedure

Use this only for buckets that have not yet moved to COSI. Perform **one
service at a time**. On any failure, stop and investigate before
proceeding to the next — most likely causes are identity typos, bucket
misspelled in the SW config, or stale pods still holding the previous
credentials.

For COSI-managed buckets, rotate by replacing the `BucketAccess` and let
the COSI driver mint the replacement `BucketInfo` Secret. Do not patch a
workload Secret for those identities.

1. Generate a new access key + secret:

   ```bash
   echo "access=$(openssl rand -hex 16) secret=$(openssl rand -hex 24)"
   ```

2. Update the SW identity in place (re-use the existing `-user`):

   ```bash
   kubectl -n default exec -i seaweedfs-master-0 -- \
     sh -c 'weed shell -master=seaweedfs-master:9333' <<EOF
   s3.configure -apply -user loki -access_key <new-key> -secret_key <new-sec> \
     -buckets loki -actions Read,Write,List,Tagging
   EOF
   ```

3. Patch the consumer secret:

   ```bash
   kubectl -n default patch secret loki-s3 --type=json -p="[
     {\"op\":\"replace\",\"path\":\"/data/MINIO_ACCESS_KEY\",\"value\":\"$(printf %s "$KEY" | base64 -w0)\"},
     {\"op\":\"replace\",\"path\":\"/data/MINIO_SECRET_KEY\",\"value\":\"$(printf %s "$SEC" | base64 -w0)\"}
   ]"
   ```

4. Bounce the consumer (adjust the resource kind per service):

   ```bash
   kubectl -n default rollout restart deploy/loki
   kubectl -n default rollout status deploy/loki --timeout=180s
   ```

   For legacy `media-centre` credentials, the plex pod only read the
   secret in its `db-restore` init container at pod start. The current
   Plex backup path is COSI-managed, so verify it by triggering the
   cronjob manually:

   ```bash
   kubectl -n default create job --from=cronjob/plex-db-backup plex-db-backup-verify
   kubectl -n default wait --for=condition=complete job/plex-db-backup-verify --timeout=120s
   kubectl -n default logs job/plex-db-backup-verify
   ```

5. Verify no `AccessDenied` / auth errors in the consumer's logs, and
   that it successfully read or wrote to the bucket.

## Admin identity use cases

The `admin` identity remains unscoped and should **not** be placed in
any workload secret. Use it only for:

- Creating new buckets (`weed shell` → `s3.bucket.create`)
- Emergency access when a scoped identity is broken
- Manual `mc` / `aws s3` operations from a jump pod

To use admin from a one-off pod:

```bash
kubectl -n default exec -it seaweedfs-master-0 -- \
  sh -c "weed shell -master=seaweedfs-master:9333" <<< 's3.configure'
```

...and extract the admin `accessKey` / `secretKey` from the output.
Never commit or persist them outside SW itself.

## Verifying no workload holds the admin key

```bash
ADMIN_KEY=$(kubectl -n default exec seaweedfs-master-0 -- \
  sh -c "echo 's3.configure' | weed shell -master=seaweedfs-master:9333" 2>/dev/null \
  | python3 -c 'import json,sys,re; t=sys.stdin.read(); m=re.search(r"\"name\":\s*\"admin\".*?\"accessKey\":\s*\"([a-f0-9]+)\"", t, re.S); print(m.group(1))')

kubectl -n default get secrets -o json | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
admin = '$ADMIN_KEY'
for s in d['items']:
    for k, v in (s.get('data') or {}).items():
        try:
            if base64.b64decode(v).decode(errors='ignore') == admin:
                print(f\"{s['metadata']['name']}.{k}\")
        except Exception: pass
"
```

Expected: empty output.
