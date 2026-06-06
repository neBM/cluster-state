# Seerr Cutover

This runbook covers the completed June 6, 2026 cutover from Overseerr to the
current Seerr deployment defined in `apps/seerr/`.

For the later SQLite-to-PostgreSQL migration, use
[seerr-postgres-migration.md](seerr-postgres-migration.md).

This document remains relevant for the legacy redirect and rollback storage
boundaries introduced during that cutover.

## Current Boundaries

- `seerr.brmartin.co.uk` is the primary hostname.
- `overseerr.brmartin.co.uk` redirects to the new host after cutover.
- `seerr-config-sw` is the writable Seerr config PVC.
- `overseerr-config-sw` is retained as the legacy rollback config source.
- `seerr-litestream` is the active Litestream bucket.
- `overseerr-litestream` is retained as the rollback restore source.

## Pre-Cutover

1. Verify the repo renders cleanly:

   ```bash
   ./scripts/validate_kustomize.sh
   kubectl kustomize clusters/k3s-homelab > /dev/null
   ```

2. If `seerr-litestream` is modeled as a brownfield-import bucket, ensure the
   named SeaweedFS filer bucket exists before the COSI credentials are used:

   ```bash
   kubectl exec -n default seaweedfs-master-0 -- sh -lc \
     "printf 'fs.ls /buckets\n' | weed shell -master=seaweedfs-master:9333"
   kubectl exec -n default seaweedfs-master-0 -- sh -lc \
     "printf 'fs.mkdir /buckets/seerr-litestream\n' | weed shell -master=seaweedfs-master:9333"
   ```

   Only run the `fs.mkdir` command if `seerr-litestream` is missing from the
   `/buckets` listing.

3. Ensure the new bucket resources exist after reconciliation:

   ```bash
   kubectl get bucket,bucketclaim,bucketaccess -n default | rg 'seerr-litestream|overseerr-litestream'
   ```

4. Quiesce request traffic if possible. Prefer a forced final snapshot from the
   current Overseerr Litestream sidecar; if you cannot do that, allow at least
   one full `sync-interval` window (5 minutes) after the last user-visible
   mutation before cutover.

   ```bash
   kubectl exec -n default deploy/overseerr -c litestream -- \
     litestream replicate -config /tmp/litestream.yml -once -force-snapshot
   ```

## Cutover

1. Reconcile storage access first, then apps:

   ```bash
   flux reconcile kustomization storage-cosi -n flux-system
   flux reconcile kustomization apps -n flux-system
   ```

2. Watch the old pod terminate and the new pod come up:

   ```bash
   kubectl get pods -n default -l 'app in (overseerr,seerr)' -w
   kubectl rollout status deployment/seerr -n default --timeout=300s
   ```

3. Check the bootstrap path:

   ```bash
   kubectl logs -n default deploy/seerr -c prepare-config-and-data --tail=100
   kubectl logs -n default deploy/seerr -c litestream-restore --tail=100
   kubectl logs -n default deploy/seerr -c seerr --tail=100
   kubectl logs -n default deploy/seerr -c litestream --tail=100
   ```

4. Verify the public paths:

   ```bash
   curl -I https://seerr.brmartin.co.uk
   curl -I https://overseerr.brmartin.co.uk
   ```

5. In the Seerr admin UI, set the Application URL to
   `https://seerr.brmartin.co.uk`.

## Healthy Signs

- `prepare-config-and-data` reports that the Seerr PVC was initialized or was
  already initialized.
- `litestream-restore` restores from `seerr-litestream` or falls back to
  `overseerr-litestream`, then seeds `seerr-litestream`.
- the main `seerr` container reaches readiness on
  `/api/v1/settings/public`.
- the Litestream sidecar logs a sync or snapshot against `seerr-litestream`.
- `https://overseerr.brmartin.co.uk` returns a permanent redirect to
  `https://seerr.brmartin.co.uk`.

## Rollback

Rollback is a GitOps revert, not a live patch:

1. Revert commit `feat(seerr): replace overseerr runtime`.
2. Reconcile `storage-cosi` and `apps`.
3. Confirm the legacy app restores from `overseerr-litestream` and reads
   `overseerr-config-sw`.

Keep `overseerr-config-sw` and `overseerr-litestream` in desired state until the
Seerr stability window is closed and bookmark migration is no longer needed.
