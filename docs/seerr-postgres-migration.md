# Seerr PostgreSQL Migration

This runbook covers the planned migration from Seerr's current SQLite +
Litestream runtime to the shared external PostgreSQL instance at
`192.168.1.10:5433`.

It assumes the desired-state manifest change lives on a branch and is **not**
merged or reconciled yet. Do not let Flux apply the Postgres Deployment before
the SQLite data import has completed.

## Target Boundaries

- Seerr keeps `seerr-config-sw` for `settings.json`, logs, cache, and migration
  scratch data.
- Seerr moves request/user/application data from SQLite to PostgreSQL.
- `seerr-litestream` and `overseerr-litestream` remain available only for the
  migration window and rollback boundary.
- `overseerr-config-sw` remains the legacy rollback config source until the
  stability window closes.

## Pre-Migration

1. Create a dedicated PostgreSQL role and database on `192.168.1.10:5433`.
   If local `psql` tooling is not available, use a containerized client:

   ```bash
   docker run --rm -it postgres:16-alpine \
     psql -h 192.168.1.10 -p 5433 -U postgres -d postgres
   ```

   Then create the Seerr owner boundary:

   ```sql
   CREATE ROLE seerr LOGIN PASSWORD '<seerr-db-password>';
   CREATE DATABASE seerr OWNER seerr;
   ```

2. Create the runtime secret that the Postgres Deployment will consume:

   ```bash
   kubectl create secret generic seerr-secrets -n default \
     --from-literal=DB_PASS='<seerr-db-password>'
   ```

3. Keep the branch containing the Postgres Deployment change unmerged until the
   pgloader import succeeds.

4. Verify the current desired state still renders cleanly before the maintenance
   window:

   ```bash
   ./scripts/validate_kustomize.sh
   kubectl kustomize clusters/k3s-homelab > /dev/null
   ```

## Maintenance Window

1. Suspend the broad apps reconciler so Flux does not race the manual import:

   ```bash
   flux suspend kustomization apps -n flux-system
   ```

2. Force a final Litestream snapshot from the live Seerr pod:

   ```bash
   kubectl exec -n default deploy/seerr -c litestream -- sh -lc '
   set -eu
   COSI_BUCKET_INFO=/cosi/seerr-litestream/BucketInfo
   parse_cosi_field() {
     sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2"
   }
   export LITESTREAM_ACCESS_KEY_ID=$(parse_cosi_field accessKeyID "$COSI_BUCKET_INFO")
   export LITESTREAM_SECRET_ACCESS_KEY=$(parse_cosi_field accessSecretKey "$COSI_BUCKET_INFO")
   exec litestream replicate -config /tmp/litestream.yml -once -force-snapshot
   '
   ```

3. Stop the live Seerr Deployment:

   ```bash
   kubectl scale deployment/seerr -n default --replicas=0
   kubectl wait -n default --for=delete pod -l app=seerr --timeout=180s
   ```

## Create PostgreSQL Tables

Run a one-off Seerr pod against the real `seerr-config-sw` PVC. It must **not**
match the `Service/seerr` selector.

Keep the image tag aligned with `apps/seerr/kustomization.yaml` if it changes.

```bash
kubectl delete pod seerr-postgres-bootstrap -n default --ignore-not-found
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: seerr-postgres-bootstrap
  namespace: default
  labels:
    app: seerr-postgres-bootstrap
    component: migration
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
  containers:
  - name: seerr
    image: ghcr.io/seerr-team/seerr:v3.2.0
    env:
    - name: TZ
      value: Europe/London
    - name: DB_TYPE
      value: postgres
    - name: DB_HOST
      value: 192.168.1.10
    - name: DB_PORT
      value: "5433"
    - name: DB_USER
      value: seerr
    - name: DB_NAME
      value: seerr
    - name: DB_PASS
      valueFrom:
        secretKeyRef:
          name: seerr-secrets
          key: DB_PASS
          optional: false
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
      readOnlyRootFilesystem: false
      runAsGroup: 1000
      runAsNonRoot: true
      runAsUser: 1000
      seccompProfile:
        type: RuntimeDefault
    volumeMounts:
    - name: config
      mountPath: /app/config
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: seerr-config-sw
EOF
```

Wait until Seerr has created the PostgreSQL tables, then stop it again before
the import:

```bash
kubectl logs -n default pod/seerr-postgres-bootstrap -f
kubectl delete pod seerr-postgres-bootstrap -n default
```

Healthy sign: logs reach `Server ready on port 5055`.

Important: Seerr seeds built-in rows such as `discover_slider` during this
bootstrap. Do not leave those rows in place for the `data only` import.

Before the pgloader step, truncate the seeded tables back to empty schema:

```bash
kubectl delete pod seerr-db-query -n default --ignore-not-found
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: seerr-db-query
  namespace: default
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:16-alpine
    command:
    - sh
    - -lc
    - |
      set -eu
      export PGDATABASE=seerr
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
      SELECT 'TRUNCATE TABLE ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' RESTART IDENTITY CASCADE;'
      FROM pg_tables
      WHERE schemaname = 'public'\gexec
      SQL
    env:
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef:
          name: postgres-superuser
          key: DATABASE_URL
          optional: false
EOF

kubectl wait -n default --for=jsonpath='{.status.phase}'=Succeeded pod/seerr-db-query --timeout=180s
kubectl logs -n default pod/seerr-db-query
```

## Restore the SQLite Snapshot

Restore the final SQLite snapshot from `seerr-litestream` onto the RWX config
PVC so pgloader can read it without depending on a node-local temp file.

```bash
kubectl delete pod seerr-sqlite-restore -n default --ignore-not-found
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: seerr-sqlite-restore
  namespace: default
  labels:
    app: seerr-sqlite-restore
    component: migration
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
  containers:
  - name: litestream
    image: litestream/litestream:0.5
    command: ["/bin/sh", "-lc", "sleep 7d"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      privileged: false
      readOnlyRootFilesystem: false
      runAsGroup: 1000
      runAsNonRoot: true
      runAsUser: 1000
      seccompProfile:
        type: RuntimeDefault
    volumeMounts:
    - name: config
      mountPath: /config
    - name: seerr-litestream-cosi
      mountPath: /cosi/seerr-litestream
      readOnly: true
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: seerr-config-sw
  - name: seerr-litestream-cosi
    secret:
      secretName: seerr-litestream-s3
EOF

kubectl wait -n default --for=condition=Ready pod/seerr-sqlite-restore --timeout=180s
```

Run the restore:

```bash
kubectl exec -n default pod/seerr-sqlite-restore -c litestream -- sh -lc '
set -eu
DB_DIR=/config/migration/postgres-import
DB_FILE=$DB_DIR/db.sqlite3
BUCKET_INFO=/cosi/seerr-litestream/BucketInfo
CONFIG=/tmp/litestream.yml

mkdir -p "$DB_DIR"
rm -f "$DB_FILE" "$DB_FILE-wal" "$DB_FILE-shm"

parse_cosi_field() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2"
}

LITESTREAM_BUCKET=$(parse_cosi_field bucketName "$BUCKET_INFO")
LITESTREAM_ENDPOINT=$(parse_cosi_field endpoint "$BUCKET_INFO")
LITESTREAM_ACCESS_KEY_ID=$(parse_cosi_field accessKeyID "$BUCKET_INFO")
LITESTREAM_SECRET_ACCESS_KEY=$(parse_cosi_field accessSecretKey "$BUCKET_INFO")

cat > "$CONFIG" <<EOF
dbs:
- path: $DB_FILE
  replicas:
  - bucket: ${LITESTREAM_BUCKET}
    endpoint: ${LITESTREAM_ENDPOINT}
    force-path-style: true
    name: seerr
    path: db
    type: s3
EOF

export LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY
litestream restore -config "$CONFIG" -o "$DB_FILE" "$DB_FILE"
stat -c "%n %s bytes" "$DB_FILE"
'
```

Healthy sign: the restored `db.sqlite3` is present under
`/config/migration/postgres-import/` and is materially larger than an empty
database file.

## Import with pgloader

```bash
kubectl delete pod seerr-pgloader -n default --ignore-not-found
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: seerr-pgloader
  namespace: default
  labels:
    app: seerr-pgloader
    component: migration
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/arch: amd64
  containers:
  - name: pgloader
    image: ghcr.io/ralgar/pgloader:pr-1531
    command: ["pgloader"]
    args:
    - --with
    - quote identifiers
    - --with
    - data only
    - /config/migration/postgres-import/db.sqlite3
    - postgresql://seerr:$(DB_PASS)@192.168.1.10:5433/seerr
    env:
    - name: DB_PASS
      valueFrom:
        secretKeyRef:
          name: seerr-secrets
          key: DB_PASS
          optional: false
    volumeMounts:
    - name: config
      mountPath: /config
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: seerr-config-sw
EOF
```

Run the import and wait for completion:

```bash
kubectl logs -n default pod/seerr-pgloader -f
kubectl wait -n default --for=jsonpath='{.status.phase}'=Succeeded pod/seerr-pgloader --timeout=600s
```

Important: pgloader imports the SQLite `migrations` rows, but Seerr's
PostgreSQL runtime expects its own Postgres migration history. Rewrite the
`migrations` table before starting the Postgres Deployment:

```bash
kubectl delete pod seerr-db-fixmigrations -n default --ignore-not-found
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: seerr-db-fixmigrations
  namespace: default
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:16-alpine
    command:
    - sh
    - -lc
    - |
      set -eu
      export PGDATABASE=seerr
      psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
      TRUNCATE TABLE migrations RESTART IDENTITY;
      INSERT INTO migrations (id, timestamp, name) VALUES
        (1, 1734786061496, 'InitialMigration1734786061496'),
        (2, 1734786596045, 'AddTelegramMessageThreadId1734786596045'),
        (3, 1734805738349, 'AddOverrideRules1734805738349'),
        (4, 1734809898562, 'FixNullFields1734809898562'),
        (5, 1737320080282, 'AddBlacklistTagsColumn1737320080282'),
        (6, 1743023615532, 'UpdateWebPush1743023615532'),
        (7, 1743107707465, 'AddUserAvatarCacheFields1743107707465'),
        (8, 1745492376568, 'UpdateWebPush1745492376568'),
        (9, 1746811308203, 'FixIssueTimestamps1746811308203'),
        (10, 1765233385034, 'AddUniqueConstraintToPushSubscription1765233385034'),
        (11, 1770627987304, 'AddPerformanceIndexes1770627987304'),
        (12, 1771080196816, 'RenameBlacklistToBlocklist1771080196816'),
        (13, 1771259406751, 'AddForeignKeyIndexes1771259406751'),
        (14, 1771337333450, 'RecoveryLinkExpirationDateTime1771337333450'),
        (15, 1772000000000, 'FixBlocklistIdDefault1772000000000'),
        (16, 1772048000333, 'AddMediaTypeToUniqueConstraints1772048000333');
      SQL
    env:
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef:
          name: postgres-superuser
          key: DATABASE_URL
          optional: false
EOF

kubectl wait -n default --for=jsonpath='{.status.phase}'=Succeeded pod/seerr-db-fixmigrations --timeout=180s
kubectl logs -n default pod/seerr-db-fixmigrations
```

## Cut Over to the Postgres Deployment

1. Land the branch that changes `apps/seerr/` to the Postgres runtime.
2. Refresh Flux and reconcile apps:

   ```bash
   flux reconcile source git cluster-state -n flux-system
   flux resume kustomization apps -n flux-system
   flux reconcile kustomization apps -n flux-system
   ```

3. Wait for the new Deployment:

   ```bash
   kubectl rollout status deployment/seerr -n default --timeout=300s
   kubectl logs -n default deploy/seerr -c seerr --tail=100
   curl -I https://seerr.brmartin.co.uk
   curl -I https://overseerr.brmartin.co.uk
   ```

4. Confirm existing users, requests, and application settings are still present
   in the Seerr UI.

5. Clean up the helper pods after success:

   ```bash
   kubectl delete pod seerr-sqlite-restore seerr-pgloader -n default --ignore-not-found
   ```

## Immediate Recovery Baseline

Unless the shared PostgreSQL host's backup coverage has already been verified
for the new `seerr` database, take an immediate first logical backup after the
cutover:

Use a client matching the server major version. As of June 6, 2026 the external
host is PostgreSQL `17.10`, so `postgres:17-alpine` is the correct helper:

```bash
kubectl delete pod seerr-pgdump -n default --ignore-not-found
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: seerr-pgdump
  namespace: default
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: pgdump
    image: postgres:17-alpine
    command:
    - sh
    - -lc
    - |
      set -eu
      mkdir -p /config/migration/postgres-import
      pg_dump -h 192.168.1.10 -p 5433 -U seerr -d seerr -Fc \
        -f /config/migration/postgres-import/seerr-initial-postgres.dump
      stat -c '%n %s bytes' /config/migration/postgres-import/seerr-initial-postgres.dump
    env:
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: seerr-secrets
          key: DB_PASS
          optional: false
    volumeMounts:
    - name: config
      mountPath: /config
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: seerr-config-sw
EOF

kubectl wait -n default --for=jsonpath='{.status.phase}'=Succeeded pod/seerr-pgdump --timeout=180s
kubectl logs -n default pod/seerr-pgdump
```

## Rollback

Rollback is not symmetric once traffic has reopened on PostgreSQL.

Before reopening traffic:

1. Keep `apps` suspended.
2. Revert to the SQLite Deployment branch or current `main`.
3. `flux reconcile source git cluster-state -n flux-system`
4. `flux resume kustomization apps -n flux-system`
5. `flux reconcile kustomization apps -n flux-system`

After reopening traffic:

- Treat rollback to SQLite as non-lossless.
- Recover from a PostgreSQL backup/export instead of assuming a simple Git
  revert can safely replay new writes back into SQLite.
