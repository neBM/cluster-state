# CSI Mount-Root Ownership — SeaweedFS CSI Driver

> **Status:** Context dump / proto-plan. Written 2026-04-09 after Plex crashloop incident. Convert to full plan via `superpowers:brainstorming` → `superpowers:writing-plans` before implementation.

## Incident that motivated this

2026-04-09: Plex crashlooped with `boost::filesystem::create_directories: Permission denied` on `/config/Library/Application Support/Plex Media Server/Cache`. Root cause: `/config` (SeaweedFS mount root for `plex-config`) was owned `root:root 0750`, and Plex runs as uid 990 via s6-setuidgid — could not traverse the mount root. Files *inside* the mount (restored from restic 2026-04-07) were correctly `990:997`, but unreachable because the gating root inode was wrong.

Recovered via manual `chown` + `Preferences.xml` restore from restic snapshot `09ec5f2e`. See conversation record.

## Why the existing fork didn't cover this

The `feat/volume-mount-group` fork (in-tree at `drivers/seaweedfs-csi-driver/`, tip imported as `48700ee`) wires kubelet's `volume_mount_group` (= `fsGroup`) through to weed mount as `-map.gid=FSGROUP:0`. That translates the *filer-side gid* of files **inside** the mount to the local view.

It does **not** affect the mount-root inode:

- `-map.uid` / `-map.gid` are view transformations applied by weed mount's FUSE server to file attribute lookups *inside* the tree. The root inode attributes are not passed through the same translation path. Confirmed empirically — `/config` showed `0:0 0750` even with the fork active and `fsGroup: 997` on the pod.
- The fork also does not `chown` or `chmod` the staging-target path after mount. Kubelet expects the CSI driver to handle `fsGroup`-style mount-root perms when the driver advertises `VOLUME_MOUNT_GROUP` (since kubelet explicitly *won't* walk the mount itself). Omission in `stageNewVolume`.

Documented in memory `project_seaweedfs_csi_deployment.md:21`: *"FUSE root inode doesn't get gid mapping. The mount point directory always shows 0:0 regardless of -map.gid. Files inside the mount do get mapped. This means init containers are still needed for chown/chmod on mount root dirs."*

That "init containers are still needed" caveat is what this plan removes.

## Key empirical fact

`chown 990:997 /config` run inside a consumer pod (as root) **does** propagate to filer metadata and persists across pod restarts. Verified during incident recovery: manual chown → delete pod → new pod sees `990:997` on the mount root. So the filer accepts chown on the root inode; only the `-map.gid` view-translation path bypasses it.

Implication: the fix is a single `os.Chown(stagingTargetPath, uid, gid)` in the CSI driver after the FUSE mount is established. No recursion, no per-pod init cost after the first mount, permanent.

## Proposed implementation

### Driver changes

**File:** `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go`

1. **`stageNewVolume`** (line 375): after `volume.Stage(stagingTargetPath)` succeeds and before the quota block, call a new `applyMountRootOwnership(stagingTargetPath, volContext)`. Log-only on failure — do not fail the stage, because a crashlooping consumer is easier to diagnose than `ContainerCreating` forever.

2. **New helper `applyMountRootOwnership`** (~25 lines, placed near `injectVolumeMountGroup`):
   ```go
   func applyMountRootOwnership(target string, volCtx map[string]string) error {
       uid, gid := -1, -1
       if v := volCtx["mountRootUid"]; v != "" {
           n, err := strconv.Atoi(v); if err != nil { return err }
           uid = n
       }
       if v := volCtx["mountRootGid"]; v != "" {
           n, err := strconv.Atoi(v); if err != nil { return err }
           gid = n
       }
       if uid == -1 && gid == -1 { return nil }
       if err := os.Chown(target, uid, gid); err != nil { return err }
       return os.Chmod(target, 0770) // owner+group rwx, mirror kubelet fsGroup semantics
   }
   ```

3. **`injectVolumeMountGroup`** (line 430): after setting `gidMap`, also auto-populate `mountRootGid` if unset. This means a pod with just `fsGroup: 997` in `securityContext` gets mount-root group ownership for free — no explicit StorageClass param needed for the group case.
   ```go
   if _, ok := volContext["mountRootGid"]; !ok {
       volContext["mountRootGid"] = mountGroup
   }
   ```

4. **Skip on read-only**: guard with `if !isVolumeReadOnly(req)` at the call site. Chown on a read-only mount generates noise and fails.

**File:** `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go`

5. **`buildMountArgs`** (line 184-189): add `mountRootUid` and `mountRootGid` to the `ignoredArgs` map so they don't get forwarded to `weed mount` as unknown CLI flags.

### Tests

**File:** `drivers/seaweedfs-csi-driver/test/` (existing e2e harness)

- Create a PV with `volumeAttributes.mountRootUid = "1000"`, `mountRootGid = "1000"`.
- Mount via `NodeStageVolume`.
- Assert `os.Stat(stagingTarget)` returns `uid=1000, gid=1000`.
- Assert `Mode().Perm() & 0770 == 0770`.

**Unit test** in `pkg/driver/nodeserver_test.go`:
- Test `applyMountRootOwnership` on a temp dir — `os.Chown` to self works unprivileged, no mock needed.
- Test `injectVolumeMountGroup` populates both `gidMap` AND `mountRootGid`.

### Upstream PR

Fold into the existing `feat/volume-mount-group` branch on the archive clone at `~/Documents/Personal/projects/seaweedfs-csi-driver` (remotes still misconfigured — fix those first per memory `project_seaweedfs_csi_deployment.md:31`). One PR bundling:
- `VOLUME_MOUNT_GROUP` node capability advertisement (already in-tree)
- `gidMap` injection from `volume_mount_group` (already in-tree)
- **New:** mount-root chown via `mountRootUid` / `mountRootGid` volume params
- **New:** auto-population of `mountRootGid` from `fsGroup`

Commit message should note that the three together constitute kubelet-compatible fsGroup semantics for SeaweedFS FUSE volumes, eliminating the need for per-service chown init containers.

## Terraform rollout

### Build + deploy

1. Bump `drivers/seaweedfs-csi-driver/` with the changes above. In-tree only — no need to touch the archive until the upstream PR.
2. Build new image. Tag: `v1.4.8-mountroot-perms` or `v1.4.9-split-mountroot` — follow the existing `v1.4.8-split` convention.
3. Multi-arch build (amd64 for hestia, arm64 for heracles+nyx) via `docker buildx build --platform linux/amd64,linux/arm64`.
4. Sideload tarballs to each node via `k3s ctr -n k8s.io images import` — **must** sideload; cluster registry is backed by SeaweedFS (chicken-egg). Per memory `feedback_always_sideload_seaweedfs_images.md`.
5. Bump image tag in `modules-k8s/seaweedfs/variables.tf` → `csi_driver_image_tag`, `csi_mount_image_tag`.
6. `terraform apply`. The consumer-recycler DaemonSet (shipped 2026-04-09) will automatically cycle consumer pods on each node as the mount daemon restarts. No manual pod deletion needed.

### Retrofit existing PVs (Path B — no re-provisioning)

Patch existing bound PVs to add `volumeAttributes` fields. No data movement, no StorageClass changes. Example for plex-config:

```bash
kubectl patch pv pvc-56ccf9a9-c7f8-4949-8b07-89d5a883744a --type=merge -p '
{"spec":{"csi":{"volumeAttributes":{"mountRootUid":"990","mountRootGid":"997"}}}}'
kubectl -n default delete pod -l component=plex  # force re-stage
```

CSI reads `volumeAttributes` on every `NodeStageVolume` — the patched values take effect on the next mount. Chown runs, filer metadata updates, subsequent pod restarts are fast (idempotent chown).

### Audit + backfill (Path A — per-service convention)

For new services and for cleanup of the existing pattern:

1. New StorageClasses in `modules-k8s/seaweedfs/storage-class.tf` — one per uid family:
   - `seaweedfs` (default) — no mountRoot params; relies on fsGroup auto-population only
   - `seaweedfs-plex` — `mountRootUid=990, mountRootGid=997`
   - `seaweedfs-www` — `mountRootUid=33, mountRootGid=33` (nextcloud, nginx, php-fpm)
   - `seaweedfs-mail` — TBD once mail uids are reconciled
2. Audit each SeaweedFS-backed PVC consumer in `modules-k8s/` — grep for `chown` init containers, verify whether they still need to exist post-rollout. Most should become no-ops once the mount root is correctly owned.
3. Remove `chown` init containers that are now redundant. Keep the ones that fix specific subdirectory perms (e.g. nextcloud's `chmod 0770` on the data dir — different concern from mount root).

## What NOT to do

- **Do not recurse** the chown (`chown -R`) over the mount tree. That was the rejected approach that drove this whole investigation — Plex config tree is multi-GB and recursive chown over FUSE is unacceptably slow. The fix is specifically `os.Chown(target, ...)` on the mount root only. Files inside the mount inherit correct ownership via the existing `-map.gid` fork or via explicit writes.
- **Do not change the `-umask=000` mount flag** in `mounter.go:130`. That controls *newly created file permissions*, not ownership. Leave it alone.
- **Do not conflate `uidMap`/`gidMap` with `mountRootUid`/`mountRootGid`**. The former are view-translations applied to tree contents; the latter are a one-shot chown of the root inode. Different mechanisms, different lifecycles.

## Related gaps

This is **Gap 8** in `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md` (to be added — currently only Gaps 1-7 exist). When this ships, also append Gaps 9-12 from the same conversation (readiness probes, cont-init.d clobber protection, self-service restic file restore, extended consumer alerting).

## Files at a glance

| File | Change |
|---|---|
| `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go` | +`applyMountRootOwnership`, call in `stageNewVolume`, extend `injectVolumeMountGroup` |
| `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go` | +`mountRootUid`/`mountRootGid` in `ignoredArgs` |
| `drivers/seaweedfs-csi-driver/test/` | +e2e test asserting chown applied |
| `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver_test.go` | +unit tests |
| `modules-k8s/seaweedfs/variables.tf` | Bump `csi_driver_image_tag` / `csi_mount_image_tag` |
| `modules-k8s/seaweedfs/storage-class.tf` | New per-service classes (optional, Path A) |
| (`kubectl patch pv ...`) | Retrofit existing PVs (Path B, no terraform) |

## Priority

**High.** This is the root cause of the 2026-04-09 Plex incident and silently breaks any non-root workload that consumes a SeaweedFS PVC with `fsGroup`-only semantics. Every new service has to discover this the hard way without the fix.

Effort: **S/M** — ~35 lines of Go + tests + image build + retrofit patches. Single session.
