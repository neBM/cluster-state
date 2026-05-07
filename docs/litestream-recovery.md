# Litestream Backup Recovery

This runbook covers the current SeaweedFS-era recovery flow for
Litestream-backed SQLite data.

Current live consumer:

- `overseerr` stores Litestream LTX files in bucket
  `overseerr-litestream`, prefix `db`

Related references:

- [seaweedfs-s3-identities.md](seaweedfs-s3-identities.md) for the live
  secret mappings and credential rotation flow
- [storage-troubleshooting.md](storage-troubleshooting.md) for broader
  storage failure modes

## When To Use This

Use this runbook when the Litestream-backed object data is the problem,
for example:

- `litestream restore` fails with `no matching backup files available`
- the S3 bucket/prefix was deleted or corrupted
- the workload refuses to start because its restore init container
  cannot rebuild the local SQLite file from object storage

Do not use this runbook to repair a local SQLite file in place. The
current Litestream consumer restores its local database from SeaweedFS
S3 at startup, so the durable recovery target is the bucket contents.

## Important Constraints

- The restic backup covers the SeaweedFS filer root through the
  read-only PVC `restic-seaweedfs-filer-root`.
- That means recovery is a two-step process:
  1. restore the bucket contents from restic into scratch space
  2. push the restored files back into SeaweedFS S3
- Do not try to write back through `restic-seaweedfs-filer-root`; it is
  intentionally read-only.
- The restic backup excludes `*-wal` and `*-shm`. That is expected and
  does not block Litestream object recovery because the bucket stores
  LTX files, not the live local WAL/shm files.

## Overseerr Recovery

Set the recovery variables:

```bash
NS=default
WORKLOAD=deployment/overseerr
BUCKET=overseerr-litestream
PREFIX=db
SECRET=overseerr-secrets
HELPER=litestream-recovery
```

Stop Overseerr so nothing keeps mutating the bucket while you restore:

```bash
kubectl scale "$WORKLOAD" -n "$NS" --replicas=0
kubectl wait -n "$NS" --for=delete pod -l app=overseerr --timeout=180s
```

Create a helper pod on `hestia` with:

- the restic repository mounted from `/mnt/csi/backups/restic`
- scratch space shared between a `restic` container and an `rclone`
  container
- the live service secret loaded into the `rclone` container

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER}
  namespace: ${NS}
spec:
  nodeSelector:
    kubernetes.io/hostname: hestia
  restartPolicy: Never
  containers:
  - name: restic
    image: restic/restic:0.18.1
    command: ["sh", "-lc", "sleep 7d"]
    volumeMounts:
    - name: repo
      mountPath: /repo
    - name: restore
      mountPath: /restore
    - name: restic-secret
      mountPath: /secrets
      readOnly: true
  - name: rclone
    image: rclone/rclone:latest
    command: ["sh", "-lc", "sleep 7d"]
    env:
    - name: S3_ENDPOINT
      value: http://seaweedfs-s3.default.svc.cluster.local:8333
    envFrom:
    - secretRef:
        name: ${SECRET}
    volumeMounts:
    - name: restore
      mountPath: /restore
  volumes:
  - name: repo
    hostPath:
      path: /mnt/csi/backups/restic
      type: Directory
  - name: restore
    emptyDir: {}
  - name: restic-secret
    secret:
      secretName: restic-backup-secrets
      items:
      - key: RESTIC_PASSWORD
        path: password
EOF

kubectl wait -n "$NS" --for=condition=Ready pod/"$HELPER" --timeout=180s
```

Open a shell in the `restic` container and inspect snapshots for the
bucket path:

```bash
kubectl exec -it -n "$NS" pod/"$HELPER" -c restic -- sh
```

Inside the container:

```bash
export RESTIC_REPOSITORY=/repo
export RESTIC_PASSWORD_FILE=/secrets/password

restic snapshots --path "/data-seaweedfs/$BUCKET"
```

Pick the snapshot you want, then restore just the Litestream prefix into
scratch space:

```bash
restic restore <snapshot-id> \
  --include "/data-seaweedfs/$BUCKET/$PREFIX" \
  --target /restore

find "/restore/data-seaweedfs/$BUCKET/$PREFIX" -maxdepth 3 | sed -n '1,40p'
exit
```

Open a shell in the `rclone` container:

```bash
kubectl exec -it -n "$NS" pod/"$HELPER" -c rclone -- sh
```

First, preserve the current live prefix before you overwrite it:

```bash
rclone copy ":s3:$BUCKET/$PREFIX" /restore/live-before-recovery \
  --s3-provider Other \
  --s3-endpoint "$S3_ENDPOINT" \
  --s3-access-key-id "$MINIO_ACCESS_KEY" \
  --s3-secret-access-key "$MINIO_SECRET_KEY" \
  --s3-force-path-style \
  --s3-no-check-bucket
```

Then wipe the current prefix and upload the restored files:

```bash
rclone purge ":s3:$BUCKET/$PREFIX" \
  --s3-provider Other \
  --s3-endpoint "$S3_ENDPOINT" \
  --s3-access-key-id "$MINIO_ACCESS_KEY" \
  --s3-secret-access-key "$MINIO_SECRET_KEY" \
  --s3-force-path-style \
  --s3-no-check-bucket

rclone copy "/restore/data-seaweedfs/$BUCKET/$PREFIX" ":s3:$BUCKET/$PREFIX" \
  --s3-provider Other \
  --s3-endpoint "$S3_ENDPOINT" \
  --s3-access-key-id "$MINIO_ACCESS_KEY" \
  --s3-secret-access-key "$MINIO_SECRET_KEY" \
  --s3-force-path-style \
  --s3-no-check-bucket

rclone lsf ":s3:$BUCKET/$PREFIX" \
  --s3-provider Other \
  --s3-endpoint "$S3_ENDPOINT" \
  --s3-access-key-id "$MINIO_ACCESS_KEY" \
  --s3-secret-access-key "$MINIO_SECRET_KEY" \
  --s3-force-path-style \
  --s3-no-check-bucket | head

exit
```

Delete the helper pod and start Overseerr again:

```bash
kubectl delete pod/"$HELPER" -n "$NS"
kubectl scale "$WORKLOAD" -n "$NS" --replicas=1
kubectl rollout status "$WORKLOAD" -n "$NS" --timeout=300s
```

Validate the restore:

```bash
kubectl logs -n "$NS" deploy/overseerr -c litestream-restore --tail=100
kubectl logs -n "$NS" deploy/overseerr -c overseerr --tail=100
kubectl get deploy overseerr -n "$NS"
```

Healthy signs:

- `litestream-restore` logs `Database restored successfully from S3`
- the final size check passes
- the main `overseerr` container reaches `Server ready on port 5055`

## Known SeaweedFS-Specific Failure Mode

If restore hangs or fails with `decode header: EOF`, the problem may be
the `seaweedfs-s3` gateway rather than the backup data. There is a known
failure mode where the gateway keeps a stale vidMap entry.

Fast recovery:

```bash
kubectl rollout restart deployment/seaweedfs-s3 -n default
kubectl rollout status deployment/seaweedfs-s3 -n default --timeout=180s
```

Then retry the Litestream restore before doing a full bucket recovery.

## Secret And Metadata Hygiene

- The current service secret mappings are documented in
  [seaweedfs-s3-identities.md](seaweedfs-s3-identities.md).
- These secrets are plain Kubernetes `Secret` objects today.
- Avoid `kubectl apply` when rotating or repairing them. Use
  `kubectl patch` or recreate them explicitly so you do not reintroduce
  `kubectl.kubernetes.io/last-applied-configuration` with secret content
  embedded in metadata.
