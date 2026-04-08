# SeaweedFS S3 Identity Management

Per-service S3 identities, scoped to individual buckets. The shared
`admin` identity is reserved for operator use only (bucket creation,
emergency access); all workloads use scoped identities.

## Identity → bucket → secret mapping

| Identity | Bucket | K8s Secret | Key names | Consumers |
|---|---|---|---|---|
| `loki` | `loki` | `loki-s3` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | Deployment/loki |
| `victoriametrics` | `victoriametrics` | `victoriametrics-s3` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | Deployment/victoriametrics |
| `media-centre` | `plex-backup` | `media-centre-secrets` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | StatefulSet/plex (db-restore init), CronJob/plex-db-backup |
| `athenaeum` | `athenaeum-attachments` | `athenaeum-secrets` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | Deployment/athenaeum-backend |
| `gitlab-runner` | `gitlab-runner-cache` | `gitlab-runner-cache-s3` | `accesskey`, `secretkey` | Deployments gitlab-runner-{amd64,any,arm64} |
| `overseerr` | `overseerr-litestream` | `overseerr-secrets` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | Deployment/overseerr |
| `admin` | *(unscoped, full Admin)* | *(not in any workload secret)* | — | Operator use only |

All scoped identities have actions `Read,Write,List,Tagging` on their
bucket only. `admin` has the additional `Admin` action cluster-wide.

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

## Rotation procedure

Perform **one service at a time**. On any failure, stop and investigate
before proceeding to the next — most likely causes are identity typos,
bucket misspelled in the SW config, or stale pods still holding the
previous credentials.

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

   Note: `gitlab-runner-cache-s3` uses lowercase `accesskey` / `secretkey`
   instead of the `MINIO_*` convention.

4. Bounce the consumer (adjust the resource kind per service):

   ```bash
   kubectl -n default rollout restart deploy/loki
   kubectl -n default rollout status deploy/loki --timeout=180s
   ```

   For `media-centre`, the plex StatefulSet only reads the secret in its
   `db-restore` init container at pod start — a running plex pod does
   not need to be restarted. Instead, verify the rotation by triggering
   the cronjob manually:

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
