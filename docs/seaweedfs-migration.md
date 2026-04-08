# SeaweedFS Migration Plan

This document describes the migration from GlusterFS + NFS-Ganesha + MinIO to SeaweedFS.

## Background

### Why Migrate

The current storage stack is three layers deep:

```
GlusterFS bricks → NFS-Ganesha (FSAL_GLUSTER) → nfs-subdir-provisioner → PVCs
                                                                        ↘ MinIO (S3 re-export)
```

Each layer has produced production incidents (see `storage-troubleshooting.md`):

- GlusterFS DHT fileid churn on cross-brick renames
- NFS-Ganesha TCP listener bugs (Issue #1358, build-from-source required)
- Kernel 6.18 directory_delegations incompatibility with Ganesha's GLUSTER FSAL
- MinIO re-exporting GlusterFS-backed storage as S3 — extra daemon, extra failure mode

SeaweedFS replaces all three layers with a single system: native S3 API, native CSI driver,
native POSIX filer, Apache 2.0 licensed, ARM64-native, lightweight enough for Pi nodes.

### Target Architecture

```
SeaweedFS volume servers (one per node) ─┐
                                         ├─→ Filer ─→ CSI driver ─→ PVCs
                                         └─→ S3 gateway ──────────→ Services (loki, vm, media-centre, ...)
                                         
                                         Master (Raft quorum, 3 replicas)
```

### Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replication policy | `000` (no replication) | Matches current Gluster config; restic mitigates data loss |
| Volume servers | DaemonSet on Heracles + Nyx only (node selector) | Hestia has no storage brick — matches current Gluster topology. Master auto-balances across available volume servers by free capacity |
| Master quorum | 3 replicas (Raft) | Match node count |
| Filer metadata backend | leveldb (embedded) | Zero-ops, isolated per filer instance; etcd rejected (k8s blast radius), Postgres rejected (no in-cluster instance). Upgrade path to Postgres exists if needed later |
| Filer placement | DaemonSet across all nodes | HA — no single-node pinning |
| S3 gateway | `weed s3` | Drops MinIO dependency entirely |
| CSI driver | `seaweedfs-csi-driver` | Official, Apache 2.0 |
| Volume data path | `/data/seaweedfs/` | Coexists with `/data/glusterfs/brick1` during migration |

## Pre-Migration

### Current State Inventory

| Node | IP | OS | Arch | Role |
|------|-----|-----|------|------|
| Hestia | 192.168.1.5 | Fedora 43 | amd64 | Brick, Ganesha, MinIO |
| Heracles | 192.168.1.6 | Ubuntu 25.10 | arm64 | Brick, Ganesha, glusterd |
| Nyx | 192.168.1.7 | Ubuntu 25.10 | arm64 | Brick, Ganesha, glusterd |

### PVC Consumers (StorageClass `glusterfs-nfs`)

Discovered from `modules-k8s/*/main.tf`:

- iris, mail, media-centre, gitlab, vaultwarden, nextcloud, minio, open-webui,
  matrix, nginx-sites, overseerr, searxng, laurens-dissertation

### S3 (MinIO) Consumers

Discovered from `kubernetes.tf` and modules:

| Service | Bucket | Purpose |
|---------|--------|---------|
| loki | `loki` | Chunks + index |
| victoriametrics | `victoriametrics` | vmbackup snapshots |
| media-centre | plex backup bucket | sqlite database snapshots |
| gitlab / gitlab-runner | (various) | Runner caches, artefacts |
| overseerr | (db backup) | Litestream WAL |
| athenaeum | (db backup) | Litestream WAL |

### Disk Headroom Check

Before starting, confirm each node has free space ≥ largest migrating PVC on the
filesystem that will host `/data/seaweedfs/`. If bricks share a disk with the OS,
check `df -h` per node and plan staggered migration accordingly.

## Migration Phases

### Phase 0 — Pilot Stand-Up (~1 day)

**Goal:** SeaweedFS running alongside Gluster, no workloads migrated yet.

1. Create `modules-k8s/seaweedfs/` terraform module:
   - Master StatefulSet (3 replicas, Raft quorum)
   - Volume server DaemonSet, `hostPath: /data/seaweedfs`, `dataCenter=home`, `rack=<node>`
   - Filer StatefulSet (1 replica initially, embedded leveldb)
   - S3 gateway Deployment
   - CSI driver DaemonSet + controller
   - StorageClass `seaweedfs` with `collection=default, replication=000`
   - Service for S3 gateway (ClusterIP `seaweedfs-s3.default.svc.cluster.local:8333`)

2. Apply module. Verify:
   ```bash
   kubectl -n default get pods -l app=seaweedfs
   kubectl -n default exec deploy/seaweedfs-master-0 -- weed shell -master=seaweedfs-master:9333
   # > cluster.check
   # > volume.list
   ```

3. Create test PVC, bind a busybox pod, write/read a file. Delete, confirm cleanup.

4. Test S3 endpoint:
   ```bash
   kubectl -n default run mc --rm -it --image=minio/mc -- sh
   # mc alias set sw http://seaweedfs-s3:8333 any any
   # mc mb sw/test && mc cp /etc/hosts sw/test/ && mc ls sw/test/
   ```

### Phase 1 — Pilot Workload (~1 day)

**Goal:** Validate POSIX semantics and performance under real load.

1. Pick `searxng` or `overseerr` (low-risk, small data, non-critical).
2. Stop the deployment.
3. `rsync` data from `/storage/v/glusterfs_<service>_data/` → new SeaweedFS PVC.
4. Update module to use `storage_class_name = "seaweedfs"`.
5. Apply, verify service recovery.
6. Smoke test: confirm app loads, data intact, basic writes work.

**Decision gate:** If pilot fails, fix root cause or abort. Rollback is minutes
(flip StorageClass back). No extended observation period — restic covers data risk.

### Phase 2 — Restic Backup Migration

**Goal:** Restic backs up SeaweedFS data before any real workloads move.

The restic CronJob (`modules-k8s/restic-backup/`) currently mounts `hostPath: /storage/v`
(the Ganesha NFS export of GlusterFS). This path won't exist after Gluster is removed.

1. **Update source volume:** Replace the `hostPath /storage/v` volume with a SeaweedFS
   filer PVC that exposes the filer root. This gives restic the same tree-of-directories
   view it has today.

2. **Update tags:** `--tag glusterfs` → `--tag seaweedfs`.

3. **Update excludes:** Review `glusterfs_ollama_data` and other `glusterfs_*` patterns
   in `excludes.txt` — PVC directory naming may change under the SeaweedFS CSI provisioner's
   `pathPattern`.

4. **Node pinning stays:** The backup *destination* (`/mnt/csi/backups/restic`) is a
   hostPath on Hestia. The node selector remains.

5. **Run a manual backup** to verify the new source is picked up correctly:
   ```bash
   kubectl -n default create job --from=cronjob/restic-backup restic-test-$(date +%s)
   kubectl -n default logs -f job/restic-test-*
   ```

6. **Verify snapshot:** Confirm the new snapshot contains SeaweedFS-backed paths and
   the old Gluster snapshot chain is still intact (restic stores both; no data lost).

**Important:** Complete this before migrating workloads in Phase 3. Every migrated
service must be covered by restic from day one on the new storage.

### Phase 3 — Stateless and Low-Risk PVCs

**Goal:** Migrate PVCs holding caches, media, and simple configs.

Order (lowest risk first):
1. nginx-sites (static content)
2. laurens-dissertation (static)
3. open-webui (config)
4. iris (config)
5. mail (config + spool)
6. media-centre (large media — plan for rsync wall clock)
7. nextcloud (large data — plan for rsync wall clock)

**Per-service procedure** (see below).

### Phase 4 — Stateful Services with Databases

**Goal:** Migrate services where PVC contains SQLite/app DBs.

Order:
1. vaultwarden (SQLite, restic-backed)
2. matrix (SQLite, restic-backed)
3. lldap (SQLite)
4. gitlab (largest stateful footprint — do last in this phase)

Use the same **rsync procedure** as Phase 3. Services are scaled to 0 before
migration so DBs are not live during the copy — no consistency risk.

### Phase 5 — MinIO Cutover

**Goal:** Replace MinIO with SeaweedFS S3; decommission MinIO.

1. Move S3 credentials from ConfigMap (`seaweedfs-s3-config`) to a Kubernetes Secret.
   The Phase 0 pilot uses a plaintext ConfigMap for convenience — rotate the keys
   and store them in a Secret before exposing the endpoint to real workloads.
2. Create production S3 credentials in SeaweedFS (`weed shell` → `s3.configure`).
2. For each bucket, `mc mirror` from MinIO → SeaweedFS S3:
   ```bash
   mc alias set minio http://minio-api:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
   mc alias set sw http://seaweedfs-s3:8333 $SW_ACCESS_KEY $SW_SECRET_KEY
   mc mb sw/loki && mc mirror minio/loki sw/loki
   # repeat per bucket
   ```
3. Verify object counts and spot-check checksums:
   ```bash
   mc du minio/loki && mc du sw/loki
   ```
4. Update consumer services to point at new S3 endpoint. Update:
   - `kubernetes.tf` — `minio_endpoint` locals
   - Secret rotation: update `*-minio` secrets with SeaweedFS credentials (or keep same keys for zero config churn — just rename the secret semantic)
5. Apply module-by-module, verify each consumer (loki, vm, media-centre, gitlab) still ingests/restores.
6. Stop MinIO deployment. Leave PVC in place for 1 week as rollback insurance.
7. After 1 week, delete MinIO module, PVC, and data directory.

### Plex-backup historical data

MinIO `plex-backup` contains 432 GiB of pre-cutover historical backups
(blobs/ and library/ prefixes, oldest 2026-01-29). These will be
dropped in Phase 6 along with MinIO. Not mirrored to SeaweedFS
because:

- Current SW backups are functional (48-object rolling window per prefix)
- Historical Plex DB state has diverged; recovery value is ~zero
- Restic covers the live PVC going forward

### Phase 6 — Cleanup

**Goal:** Remove Gluster stack entirely.

1. Confirm no remaining PVCs on `glusterfs-nfs` StorageClass:
   ```bash
   kubectl get pvc -A -o jsonpath='{range .items[?(@.spec.storageClassName=="glusterfs-nfs")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
   ```
2. Delete modules in one PR:
   - `modules-k8s/nfs-provisioner/`
   - `modules-k8s/gluster-ganesha-watcher/`
   - `modules-k8s/minio/`
3. On each node, stop and disable services:
   ```bash
   sudo systemctl disable --now nfs-ganesha-local
   sudo systemctl disable --now glusterd
   ```
4. Remove the kernel 6.18 `directory_delegations=N` workaround:
   ```bash
   sudo rm /etc/modprobe.d/nfs-ganesha-workaround.conf
   ```
5. Archive GlusterFS brick data (don't delete immediately):
   ```bash
   sudo mv /data/glusterfs /data/glusterfs.archived.$(date +%Y%m%d)
   ```
6. Wait 2+ weeks with good restic backups. Then delete archive:
   ```bash
   sudo rm -rf /data/glusterfs.archived.*
   ```
7. Remove Gluster packages.
8. Update `storage-troubleshooting.md` and `glusterfs-architecture.md` — either
   archive them into `docs/archived/` or rewrite for SeaweedFS.

## Per-Service Migration Procedure

Standard steps for each PVC migration. Tested during Phase 1 (searxng).

### Step 1 — Scale down the workload

```bash
kubectl scale -n default deploy/<service> --replicas=0
# For StatefulSets: kubectl scale -n default sts/<service> --replicas=0
```

### Step 2 — Add a new SeaweedFS PVC alongside the old one

In the service's `main.tf`, add a **second** PVC resource (keep the old one intact):

```hcl
resource "kubernetes_persistent_volume_claim" "config_seaweedfs" {
  metadata {
    name      = "<service>-config-sw"   # "-sw" suffix to avoid name collision
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"   # match original size
      }
    }
  }
}
```

Apply only the new PVC:

```bash
terraform apply -target=module.k8s_<service>.kubernetes_persistent_volume_claim.config_seaweedfs -auto-approve
kubectl get pvc <service>-config-sw   # verify Bound
```

### Step 3 — Rsync data

Single command — runs rsync inline and deletes the pod on completion:

```bash
kubectl -n default run migrator --rm -i --restart=Never \
  --image=instrumentisto/rsync-ssh \
  --overrides='{"spec":{"containers":[{"name":"migrator","image":"instrumentisto/rsync-ssh","command":["sh","-c","rsync -aHAX --info=progress2 /src/ /dst/ && echo MIGRATION_COMPLETE"],"volumeMounts":[{"name":"src","mountPath":"/src"},{"name":"dst","mountPath":"/dst"}]}],"volumes":[{"name":"src","persistentVolumeClaim":{"claimName":"<old-pvc>"}},{"name":"dst","persistentVolumeClaim":{"claimName":"<new-pvc>"}}]}}'
```

Replace `<old-pvc>` (e.g. `searxng-config`) and `<new-pvc>` (e.g. `searxng-config-sw`).
Wait for `MIGRATION_COMPLETE` in output before proceeding.

For databases, use the restic restore flow instead (see `litestream-recovery.md`).

### Step 4 — Swap Terraform to use new PVC

In `main.tf`, replace both PVC resources with a single one pointing at SeaweedFS:

```hcl
resource "kubernetes_persistent_volume_claim" "config" {
  metadata {
    name      = "<service>-config-sw"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}
```

Then fix Terraform state (old PVC removed from state but kept in cluster as rollback):

```bash
terraform state rm module.k8s_<service>.kubernetes_persistent_volume_claim.config
terraform state mv \
  module.k8s_<service>.kubernetes_persistent_volume_claim.config_seaweedfs \
  module.k8s_<service>.kubernetes_persistent_volume_claim.config
```

Apply the module (this updates the deployment to reference the new PVC and scales it back up):

```bash
terraform plan -target=module.k8s_<service>    # expect: 0 add, 1 change, 0 destroy
terraform apply -target=module.k8s_<service> -auto-approve
```

### Step 5 — Smoke test

```bash
kubectl rollout status deploy/<service> --timeout=60s
kubectl get pods -l app=<service>
kubectl exec deploy/<service> -- ls -la <mount-path>    # verify files present
kubectl exec deploy/<service> -- wget -q -O /dev/null --spider http://localhost:<port>/healthz && echo OK
```

### Step 6 — Cleanup (after ≥ 1 week)

```bash
kubectl delete pvc <service>-config    # old glusterfs PVC
```

### Rollback (per service)

```bash
kubectl scale -n default deploy/<service> --replicas=0
# Re-add old PVC to Terraform state:
terraform import module.k8s_<service>.kubernetes_persistent_volume_claim.config default/<service>-config
# Edit module: storage_class_name = "glusterfs-nfs", name = "<service>-config"
terraform apply -target=module.k8s_<service>
```

## CSI Mount Memory Sizing

The SeaweedFS CSI node DaemonSet runs a single `seaweedfs-mount` container per node.
This container spawns one `weed mount` process per FUSE-mounted PVC on that node, and
**all processes share a single cgroup memory limit**.

### Per-mount write buffer formula

Each `weed mount` allocates `chunkSizeLimitMB × concurrentWriters` for write buffers.
Defaults (4MB × 32 = 128MB) caused OOM under bulk writes during migration. Reduced to
2MB × 8 = 16MB via StorageClass `mountOptions` (`chunkSizeLimitMB=2`, `concurrentWriters=8`).

### Steady-state memory per mount

Write buffers are only part of the picture. Each `weed mount` also carries Go runtime
overhead, metadata caches, and read buffers. In practice, expect **~150-200Mi per mount**
at steady state.

### Sizing the container limit

Multiply per-mount cost by the number of SeaweedFS PVCs scheduled on the busiest node:

```
limit = (mounts_on_node × ~200Mi) + headroom
```

As of 2026-04-07, Hestia has 7 SeaweedFS FUSE mounts (~1.2Gi observed), so the limit
is set to 2Gi with `GOMEMLIMIT=1800MiB`. The original 1Gi limit caused repeated OOM
kills of `weed mount` processes, which killed the FUSE mounts and crashed Plex.

**If adding more SeaweedFS PVCs to a node, re-check this limit.**

## fsGroup and File Ownership

SeaweedFS FUSE mounts do **not** honour kernel-level `fsGroup` (unlike NFS-Ganesha).
Files presented by the FUSE mount default to `root:root` ownership and `0777`
permissions (`-umask=000`), which breaks services that run as non-root and/or
validate data directory permissions (Nextcloud: "data directory is readable by
other people").

### Solution: custom CSI driver with VOLUME_MOUNT_GROUP

The upstream `seaweedfs-csi-driver` does not implement the CSI
`VOLUME_MOUNT_GROUP` capability. A fork at
`/home/ben/Documents/Personal/projects/seaweedfs-csi-driver` (branch
`feat/volume-mount-group`) adds it:

1. Advertises `VOLUME_MOUNT_GROUP` in `NodeGetCapabilities`.
2. Extracts `volume_mount_group` (the pod's `fsGroup`) from
   `NodeStageVolume`/`NodePublishVolume` requests.
3. Injects it as `gidMap` into the volume context, which `mounter.go` translates
   to `-map.gid` on the `weed mount` invocation.

Images: `registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v1.4.6-fsgroup2` and
`registry.brmartin.co.uk/ben/seaweedfs-mount:v1.4.6-fsgroup2` (multiarch).

### CSIDriver object needs `fsGroupPolicy: File`

Without this, Kubernetes defaults to `ReadWriteOnceWithFSType`, and kubelet will
**not** pass `volume_mount_group` in the CSI request for FUSE volumes (which have
no `fsType`). The `hashicorp/kubernetes` provider's `kubernetes_csi_driver_v1`
resource does **not** support `fs_group_policy` — the CSIDriver is managed via
`kubectl_manifest` in `modules-k8s/seaweedfs/csi.tf` instead.

### SeaweedFS `-map.gid` gotcha: format is LOCAL:FILER

Easy to get backwards. The format is `-map.gid=<local_gid>:<filer_gid>`:

- **Reads** (`FilerToLocal`): files stored with `filer_gid` display locally as `local_gid`.
- **Writes** (`LocalToFiler`): files created by `local_gid` are stored as `filer_gid`.
- **Only the exact IDs in the map are translated.** All other gids pass through
  unchanged.

To make files stored as root (gid 0) appear as fsGroup 33 locally, use
`-map.gid=33:0`, **not** `-map.gid=0:33`. The CSI driver's
`injectVolumeMountGroup` constructs this as `<fsGroup>:0`.

### FUSE mount root inode doesn't get the mapping

A quirk of SeaweedFS FUSE: the mount point root directory always reports as the
mounting process's uid/gid (root in the CSI container), regardless of `-map.gid`.
Files *inside* the mount get the mapping correctly. This means a small init
container is still required to `chown` the mount root directories — but it's no
longer recursive, so it stays O(1) as data grows.

Example (nextcloud, `modules-k8s/nextcloud/main.tf`):

```hcl
init_container {
  name  = "fix-data-perms"
  image = "busybox:1"
  command = ["sh", "-c", "chown 33:33 /nc-data && chmod 0770 /nc-data && chown 33:33 /nc-config /nc-custom-apps"]
  # volume mounts for data, config, custom-apps
}
```

The `chmod 0770` is needed because `-umask=000` presents everything as `0777`
and Nextcloud rejects world-readable data directories.

### CSI node DaemonSet rollout = stale mounts everywhere

Any rollout of `seaweedfs-csi-node` kills the FUSE daemons, which leaves every
running pod with stale mounts (`Transport endpoint is not connected`). The init
container in the DaemonSet cleans up stale `globalmount` dirs so new pods can
mount, but **existing running pods do not recover** — they need a restart.

After a CSI node rollout, bounce every pod that uses a SeaweedFS PVC. The
registry (which is itself backed by SeaweedFS) creates a chicken-and-egg: if the
CSI node on the registry's host is the one pulling new images, it can't, because
the registry's storage is stale. Workaround: `kubectl cordon` the host, force a
registry reschedule, then `kubectl uncordon`.

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| POSIX semantics break SQLite/Litestream | Medium | Pilot with SQLite-backed service in Phase 1; restic snapshots as safety net |
| FUSE mount instability | Medium | Monitor during pilot week; fall back to Gluster if chronic |
| Pi memory pressure from filer + volume server + S3 | Medium | Profile after Phase 0; consider externalising filer to amd64 node (Hestia) |
| Filer metadata loss (leveldb corruption) | Low | Backup filer DB nightly; upgrade to Postgres backend for production |
| `mc mirror` incomplete bucket copy | Low | Verify with `mc du` + spot checksum; keep MinIO running until Phase 5 |
| S3 credentials break consumer service | Medium | Roll out one consumer at a time; keep old MinIO endpoint resolvable during cutover |
| Disk exhaustion during parallel run | Medium | Check `df -h` pre-flight; migrate largest PVCs to nodes with most headroom first |

## Validation Checklist

Track completion in PR description:

- [x] Phase 0: SeaweedFS module applied, test PVC + S3 bucket working
- [x] Phase 1: Pilot workload (searxng) migrated to seaweedfs, smoke test passed (2026-04-06)
- [x] Phase 2: Restic backup covering SeaweedFS, manual run verified (2026-04-06, snapshots 404af7fc + 1b01a29e)
- [x] Phase 3: All stateless PVCs migrated (2026-04-06)
- [x] Phase 4: All stateful services migrated (2026-04-06)
- [x] Phase 5: All MinIO buckets mirrored, consumers cut over to SeaweedFS S3 (2026-04-06)
- [ ] Phase 6: Gluster/Ganesha/MinIO modules deleted, systemd services disabled
- [ ] Kernel 6.18 workaround removed
- [ ] `glusterfs-architecture.md` and `storage-troubleshooting.md` updated or archived

## References

- [SeaweedFS GitHub](https://github.com/seaweedfs/seaweedfs)
- [SeaweedFS CSI Driver](https://github.com/seaweedfs/seaweedfs-csi-driver)
- [SeaweedFS S3 API docs](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [Filer metadata backends](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Stores)
- Related internal docs: `glusterfs-architecture.md`, `storage-troubleshooting.md`, `nfs-ganesha-migration.md`, `litestream-recovery.md`
