# CSI Mount-Root Ownership — Design Spec

**Date:** 2026-04-09
**Status:** Approved design, ready for implementation planning
**Predecessor:** `docs/superpowers/plans/2026-04-09-csi-mount-root-ownership.md` (proto-plan / context dump)
**Incident:** Plex crashloop 2026-04-09 (`boost::filesystem::create_directories: Permission denied` on `/config/...`)

## Problem

The in-tree SeaweedFS CSI fork at `drivers/seaweedfs-csi-driver/` wires kubelet's `VOLUME_MOUNT_GROUP` (= `fsGroup`) through to `weed mount` as `-map.gid=FSGROUP:0`. That translation applies to files *inside* the FUSE tree but **not to the mount-root inode itself**, which stays at whatever the filer stores (typically `0:0 0750` for a freshly-provisioned volume). Any non-root workload — Plex uid 990, Nextcloud www-data 33, etc. — cannot traverse the mount root unless something explicitly chowns it.

Previously worked around with per-service chown init containers. Rejected as a durable pattern: recursive chown over multi-GB Plex config trees through FUSE is unacceptably slow, and single-inode chown init containers (as Nextcloud does) are boilerplate every new service discovers the hard way.

## Goal

A durable, filer-authoritative mechanism for declaring "this volume's mount root should be owned by uid X, gid Y" on a per-PVC basis, with a single StorageClass, using the standard CSI CreateVolume → VolumeContext → NodeStage path. Eliminates the need for chown init containers for any SeaweedFS-backed workload. Retrofit for existing PVs uses the same code path as new PVs.

## Design at a glance

- **One StorageClass** (`seaweedfs`) serves every workload. No per-service classes.
- **Per-PVC intent** via two annotations:
  - `seaweedfs.csi.brmartin.co.uk/mount-root-uid: "990"`
  - `seaweedfs.csi.brmartin.co.uk/mount-root-gid: "997"`
- **Direct filer metadata writes** via `filer_pb.Mkdir` (new-volume path) and `filer_pb.UpdateEntry` (stage path). No `os.Chown` through FUSE.
- **fsGroup auto-derivation:** when `mountRootGid` is not explicitly annotated but kubelet passes `VolumeMountGroup` on the capability, the driver auto-populates `mountRootGid = fsGroup`. Today's cluster has 13 SeaweedFS consumers, all of which set `fsGroup`, so the fix is automatic on pod cycle for every one of them after the image bump.
- **Fail-loud on errors:** `CreateVolume` returns `InvalidArgument` for malformed annotations, `Internal` for k8s/filer errors. `NodeStageVolume` returns `Internal` if the filer write fails, surfacing a clear kubelet event on the pod.
- **Hardcoded mode** `0770 | os.ModeDir`. Matches kubelet fsGroup semantics. No `mount-root-mode` annotation shipped in v1 (YAGNI).

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| `os.Chown(stagingTargetPath, ...)` post-mount (proto-plan's original) | FUSE round-trip, race window between Stage success and chown, fights the filer source-of-truth model. Same LOC as filer_pb but strictly inferior. |
| Mount args (`weed mount -rootUid/-rootGid`) | Confirmed not to exist in `weed/command/mount.go` MountOptions. Adding them would require an upstream `seaweedfs` fork — out of scope per monorepo-layout policy. |
| Per-service StorageClasses (`seaweedfs-plex`, `seaweedfs-www`) | Explicitly rejected: "There should only ever be one storage class." |
| Post-bind terraform PV patch (`kubectl_patch` flow for new PVs) | Terraform dependency graph tangles, silent-failure mode on forgotten patches. Not industry standard. Retained only as a retrofit escape hatch, not the primary mechanism. |
| Static PVs for every uid-needing workload | More boilerplate per consumer, loses dynamic provisioning. Not industry standard. |
| `kubectl -R` recursive chown / `chown -R` init containers | Multi-GB recursive chown over FUSE is the whole problem we're solving. |

## Architecture

### Data flow

```
consumer terraform module
    └── kubernetes_persistent_volume_claim_v1
            metadata.annotations:
              seaweedfs.csi.brmartin.co.uk/mount-root-uid: "990"
              seaweedfs.csi.brmartin.co.uk/mount-root-gid: "997"
            spec.storage_class_name: "seaweedfs"
                │
                ▼
    csi-provisioner sidecar                            modules-k8s/seaweedfs/csi.tf
            NEW arg: --extra-create-metadata
            injects into CreateVolumeRequest.parameters:
              csi.storage.k8s.io/pvc/name, …/pvc/namespace
                │ gRPC
                ▼
    ControllerServer.CreateVolume                      pkg/driver/controllerserver.go
      existing:  resolve volumePath, parentDir, volumeName
      NEW:       lookup PVC annotations via pkg/k8s helper,
                 parse mount-root-uid / mount-root-gid
      CHANGED:   filer_pb.Mkdir(..., fn) — fn sets Entry.Attributes
                 Uid / Gid / FileMode = 0770|ModeDir when provided
      existing:  return VolumeContext containing
                 mountRootUid / mountRootGid (if resolved)
                │
                ▼
    PV.spec.csi.volumeAttributes persisted by external-provisioner
      mountRootUid: "990"
      mountRootGid: "997"
                │ (pod scheduled, kubelet → NodeStageVolume RPC)
                ▼
    NodeServer.NodeStageVolume                         pkg/driver/nodeserver.go
      existing:  injectVolumeMountGroup(cap, volContext)
                 NEW sub-step: if mountRootGid unset but VolumeMountGroup
                   present, default mountRootGid = volume_mount_group
      NEW:       applyMountRootOwnership(ctx, ns.Driver, volumeID, volContext)
                 if mountRootUid/Gid set, filer_pb.UpdateEntry on
                 the volume dir, setting Uid/Gid/FileMode.
                 Idempotent; on error → codes.Internal.
      existing:  stageNewVolume → volume.Stage()  (mount service gRPC)
                │
                ▼
    weed mount runs                                    filer-authoritative
      FUSE getattr on root inode returns the attrs
      that filer already stores → first stat is correct,
      no post-mount chown, no race window
```

### Key properties

1. **Filer is single source of truth.** No FUSE round-trip for ownership writes. `weed mount` reads what's already there.
2. **Retrofit == new-volume.** `kubectl patch pv ... volumeAttributes.mountRootUid=…` + pod cycle → NodeStage's `applyMountRootOwnership` → `filer_pb.UpdateEntry` fixes drift. Same code path.
3. **Belt-and-suspenders.** `CreateVolume` sets attrs at provisioning; `NodeStageVolume` re-applies on every stage. Any drift (including from out-of-band `weed shell fs.chown`) self-heals on next pod cycle.
4. **`NodePublishVolume` re-stage path covered for free** — it already calls `stageNewVolume`.

## API surface

### PVC-facing API

Two annotations on `kubernetes_persistent_volume_claim_v1.metadata.annotations`:

| Annotation key | Type | Required? | Semantics |
|---|---|---|---|
| `seaweedfs.csi.brmartin.co.uk/mount-root-uid` | string, parsed as int32, ≥ 0 | optional | Owner UID of the mount-root inode. If omitted and no fsGroup fallback applies, UID is left at `OS_UID` (the weed filer process's UID). |
| `seaweedfs.csi.brmartin.co.uk/mount-root-gid` | string, parsed as int32, ≥ 0 | optional | Owner GID of the mount-root inode. If omitted, falls back to `volume_mount_group` (kubelet fsGroup) when present; otherwise left unchanged. |

Parse errors (non-integer, negative) return `codes.InvalidArgument` from `CreateVolume` — PVC stuck in `Pending` with a clear provisioner event.

### VolumeContext schema (driver-internal, persisted in PV)

After `CreateVolume` returns, the bound PV's `spec.csi.volumeAttributes` contains existing keys plus:

```
mountRootUid: "990"    // only present if resolved
mountRootGid: "997"    // only present if resolved
```

These are the **internal** names the driver reads in `NodeStageVolume`. Both added to `mounter.go` `ignoredArgs` so `buildMountArgs` doesn't forward them to `weed mount` as unknown CLI flags.

### Resolution order in `injectVolumeMountGroup`

1. If `volContext["mountRootGid"]` already set (explicit annotation or retrofit PV patch) → keep it.
2. Else if `VolumeCapability.MountVolume.VolumeMountGroup` non-empty → set `volContext["mountRootGid"]` to that.
3. Else → leave unset. No filer write for gid.

`mountRootUid` has **no** auto-derivation — CSI has no runAsUser equivalent. If unset, NodeStage skips the Uid field in `UpdateEntry`, preserving the filer's existing Uid.

### Workload modes

| Mode | PVC annotations | fsGroup in pod | Filer entry ends up |
|---|---|---|---|
| fsGroup-only (plex, gitlab) | none | `997` | `*:997 0770` |
| Explicit uid+gid (nextcloud post-cleanup) | both | `33` or none | `33:33 0770` |
| Explicit gid only, no uid | gid only | usually matches | `*:<gid> 0770` |

### FileMode

Hardcoded `0770 | os.ModeDir` — matches kubelet's `fsGroupPolicy=File` semantics and nextcloud's manual `chmod 0770`. `o` bit at `0`: no current workload needs "other" access. No `mount-root-mode` annotation in v1.

### Error behavior

| Failure point | Behavior |
|---|---|
| Malformed PVC annotation int | `CreateVolume` → `codes.InvalidArgument`, PVC `Pending` with provisioner event |
| PVC lookup fails (k8s API, RBAC, network) | `CreateVolume` → `codes.Internal`, provisioner retries with backoff |
| No annotations + no fsGroup | no-op: `Mkdir` called with nil-effect fn, `NodeStage` skips filer update, mount root inherits `OS_UID:OS_GID` |
| `filer_pb.Mkdir` fails | existing error handling unchanged, provisioner retries |
| `filer_pb.UpdateEntry` fails in `NodeStage` | `NodeStageVolume` → `codes.Internal`, kubelet retries, pod `ContainerCreating` with clear event |
| `LookupEntry` returns NotFound in `NodeStage` | should not happen (volume was provisioned) — log, return `codes.FailedPrecondition` |

## Code changes, file-by-file

### 1. `modules-k8s/seaweedfs/csi.tf` — csi-provisioner args

Add one arg around `:104`:

```hcl
args = [
  "--csi-address=$(ADDRESS)",
  "--leader-election",
  "--leader-election-namespace=${var.namespace}",
  "--http-endpoint=:9809",
  "--extra-create-metadata",   # NEW
]
```

Existing controller RBAC (`csi-rbac.tf:66-70`) already grants `persistentvolumeclaims: get,list,watch,update` — sufficient for the PVC lookup.

### 2. `drivers/seaweedfs-csi-driver/pkg/k8s/pvc.go` — new helper

New file, ~30 lines. Signature:

```go
// GetPVCAnnotations fetches a PVC by namespace/name via in-cluster client
// and returns its annotations map. Returns (nil, nil) if the PVC is not
// found (caller treats absence as "no custom ownership requested").
func GetPVCAnnotations(ctx context.Context, namespace, name string) (map[string]string, error)
```

Uses `rest.InClusterConfig()` + `kubernetes.NewForConfig()` + `clientset.CoreV1().PersistentVolumeClaims(ns).Get(...)`. Cache clientset in a package-level `sync.Once`. Pattern mirrors the existing `GetVolumeCapacity` helper in `pkg/k8s/`.

### 3. `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go` — `CreateVolume`

Around the existing `filer_pb.Mkdir` call at `:87`:

```go
// NEW: resolve mount-root ownership from PVC annotations, if present
var mountRootUid, mountRootGid *int32
if pvcName, pvcNs := params["csi.storage.k8s.io/pvc/name"], params["csi.storage.k8s.io/pvc/namespace"]; pvcName != "" && pvcNs != "" {
    annotations, err := k8s.GetPVCAnnotations(ctx, pvcNs, pvcName)
    if err != nil {
        return nil, status.Errorf(codes.Internal, "lookup pvc %s/%s: %v", pvcNs, pvcName, err)
    }
    mountRootUid, err = parseOwnershipAnnotation(annotations, "seaweedfs.csi.brmartin.co.uk/mount-root-uid")
    if err != nil {
        return nil, status.Errorf(codes.InvalidArgument, "%v", err)
    }
    mountRootGid, err = parseOwnershipAnnotation(annotations, "seaweedfs.csi.brmartin.co.uk/mount-root-gid")
    if err != nil {
        return nil, status.Errorf(codes.InvalidArgument, "%v", err)
    }
}

// CHANGED: Mkdir with fn callback that sets attrs at creation time
mkdirFn := func(entry *filer_pb.Entry) {
    if mountRootUid != nil {
        entry.Attributes.Uid = uint32(*mountRootUid)
    }
    if mountRootGid != nil {
        entry.Attributes.Gid = uint32(*mountRootGid)
    }
    if mountRootUid != nil || mountRootGid != nil {
        entry.Attributes.FileMode = uint32(0770) | uint32(os.ModeDir)
    }
}
if err := filer_pb.Mkdir(ctx, cs.Driver, parentDir, volumeName, mkdirFn); err != nil {
    return nil, fmt.Errorf("error creating volume: %v", err)
}

// NEW: persist resolved values in VolumeContext for NodeStage to re-apply
if mountRootUid != nil {
    params["mountRootUid"] = strconv.FormatInt(int64(*mountRootUid), 10)
}
if mountRootGid != nil {
    params["mountRootGid"] = strconv.FormatInt(int64(*mountRootGid), 10)
}
```

Plus small file-local helper `parseOwnershipAnnotation(map[string]string, string) (*int32, error)` returning `(nil, nil)` on absent, error on bad format.

Approximate churn: +40 lines.

### 4. `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go` — stage path

Extend `injectVolumeMountGroup` at `:430`:

```go
// existing: sets gidMap
if _, ok := volContext["gidMap"]; !ok {
    volContext["gidMap"] = mountGroup + ":0"
    glog.Infof("injecting volume_mount_group %s as gidMap %s:0 (local:filer)", mountGroup, mountGroup)
}
// NEW: auto-derive mountRootGid from fsGroup if not explicitly set
if _, ok := volContext["mountRootGid"]; !ok {
    volContext["mountRootGid"] = mountGroup
    glog.Infof("auto-deriving mountRootGid=%s from volume_mount_group", mountGroup)
}
```

Add new helper near `injectVolumeMountGroup`:

```go
// applyMountRootOwnership reads mountRootUid/mountRootGid from volContext
// and applies them to the volume directory on the filer via UpdateEntry.
// No-op if neither is set. Idempotent — safe to call on every stage.
func applyMountRootOwnership(ctx context.Context, driver *SeaweedFsDriver, volumeID string, volContext map[string]string) error {
    uidStr, hasUid := volContext["mountRootUid"]
    gidStr, hasGid := volContext["mountRootGid"]
    if !hasUid && !hasGid {
        return nil
    }

    parentDir, name := path.Split(strings.TrimRight(volumeID, "/"))
    parentDir = strings.TrimRight(parentDir, "/")
    if parentDir == "" {
        parentDir = "/"
    }

    return driver.WithFilerClient(false, func(client filer_pb.SeaweedFilerClient) error {
        resp, err := filer_pb.LookupEntry(ctx, client, &filer_pb.LookupDirectoryEntryRequest{
            Directory: parentDir,
            Name:      name,
        })
        if err != nil {
            return fmt.Errorf("lookup %s/%s: %w", parentDir, name, err)
        }
        entry := resp.Entry
        if entry.Attributes == nil {
            entry.Attributes = &filer_pb.FuseAttributes{}
        }
        if hasUid {
            uid, err := strconv.ParseInt(uidStr, 10, 32)
            if err != nil {
                return fmt.Errorf("parse mountRootUid: %w", err)
            }
            entry.Attributes.Uid = uint32(uid)
        }
        if hasGid {
            gid, err := strconv.ParseInt(gidStr, 10, 32)
            if err != nil {
                return fmt.Errorf("parse mountRootGid: %w", err)
            }
            entry.Attributes.Gid = uint32(gid)
        }
        entry.Attributes.FileMode = uint32(0770) | uint32(os.ModeDir)

        return filer_pb.UpdateEntry(ctx, client, &filer_pb.UpdateEntryRequest{
            Directory: parentDir,
            Entry:     entry,
        })
    })
}
```

Wire into `stageNewVolume` at `:375`, **before** `volume.Stage()`:

```go
func (ns *NodeServer) stageNewVolume(ctx context.Context, volumeID, stagingTargetPath string, volContext map[string]string, readOnly bool) (*Volume, error) {
    // NEW: set mount-root ownership on the filer before the mount picks up attrs
    if !readOnly {
        if err := applyMountRootOwnership(ctx, ns.Driver, volumeID, volContext); err != nil {
            return nil, fmt.Errorf("apply mount-root ownership: %w", err)
        }
    }

    mounter, err := newMounter(volumeID, readOnly, ns.Driver, volContext)
    // ... existing code unchanged
}
```

Read-only guard skips filer writes on RO volumes (rare, cheap insurance).

Approximate churn: +60 lines.

### 5. `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go` — `ignoredArgs`

One delta at `:185`:

```go
ignoredArgs := map[string]struct{}{
    "dataLocality": {},
    "path":         {},
    "parentDir":    {},
    "volumeName":   {},
    "mountRootUid": {},   // NEW
    "mountRootGid": {},   // NEW
}
```

### 6. `drivers/seaweedfs-csi-driver/Makefile` — VERSION

```makefile
VERSION = v0.1.2   # was: v1.4.8-split (driver+mount) / v0.1.1 (recycler)
```

Per `project_seaweedfs_monorepo_versioning.md`, this drives all three image tags in lockstep. `-split` suffix is dropped permanently.

### 7. `modules-k8s/seaweedfs/variables.tf` — image tag bumps

```hcl
variable "csi_driver_image_tag"        { default = "v0.1.2" }  # was "v1.4.8-split"
variable "csi_mount_image_tag"         { default = "v0.1.2" }  # was "v1.4.8-split"
variable "consumer_recycler_image_tag" { default = "v0.1.2" }  # was "v0.1.1"
```

### 8. Consumer-module cleanup (optional within this phase)

- **`modules-k8s/nextcloud/main.tf:183`** — delete the `chown 33:33 /nc-data && chmod 0770 /nc-data && chown 33:33 /nc-config /nc-custom-apps` init container. Optionally add explicit annotations on the three seaweedfs-backed PVCs for declarative clarity.
- **`modules-k8s/media-centre/main.tf:206-208`** — optionally add `mount-root-uid="990", mount-root-gid="997"` annotations to the plex-config PVC for cosmetic uid match with s6-setuidgid. Leave `fs_group = 997` in place. `fs_group_change_policy = "OnRootMismatch"` is a no-op under VOLUME_MOUNT_GROUP — optional delete.

**Total churn:** ~130 lines of Go, ~10 lines of Terraform, ~20 lines of consumer-module edits.

## Testing

### Unit tests

**`pkg/driver/nodeserver_test.go`** — extend:

1. `TestInjectVolumeMountGroup_AutoDerivesMountRootGid` — capability `VolumeMountGroup: "997"`, empty volContext → assert `gidMap=="997:0"` and `mountRootGid=="997"`.
2. `TestInjectVolumeMountGroup_PreservesExplicitMountRootGid` — same capability but `volContext["mountRootGid"]="33"` → assert not overwritten.
3. `TestInjectVolumeMountGroup_NoFsGroupNoDerivation` — empty `VolumeMountGroup` → `mountRootGid` stays unset.
4. `TestApplyMountRootOwnership_NoopWhenUnset` — empty volContext → returns nil, filer not called (fake client asserts).
5. `TestApplyMountRootOwnership_ParsesValidInts` — `{"mountRootUid":"990","mountRootGid":"997"}` → fake filer asserts `UpdateEntryRequest.Entry.Attributes.{Uid==990,Gid==997,FileMode==0770|ModeDir}`.
6. `TestApplyMountRootOwnership_RejectsMalformed` — `{"mountRootUid":"not-a-number"}` → error, filer not called.
7. `TestApplyMountRootOwnership_VolumeIdPathSplit` — test `/buckets/plex-config` → `Directory="/buckets", Name="plex-config"`; edge cases `/plex-config` and `/buckets/nested/x`.

Fake `filer_pb.SeaweedFilerClient` implements only `LookupDirectoryEntry` and `UpdateEntry`; other methods panic.

**`pkg/driver/controllerserver_test.go`** (create if absent):

8. `TestCreateVolume_WithoutPVCAnnotations` — no `csi.storage.k8s.io/pvc/*` in params → `Mkdir` fn is nil-effect, returned VolumeContext has no `mountRootUid`/`mountRootGid`.
9. `TestCreateVolume_ResolvesPVCAnnotations` — mock `k8s.GetPVCAnnotations` via injectable package var → assert `Mkdir` fn sets `Uid=990, Gid=997, FileMode=0770|ModeDir`, returned VolumeContext has both keys.
10. `TestCreateVolume_InvalidUidAnnotation` — `"990abc"` → `codes.InvalidArgument`, filer not called.
11. `TestCreateVolume_OnlyGidAnnotation` — gid only → `fn` sets `Gid`, leaves `Uid` at Mkdir's `OS_UID`.

Requires a testable seam for `k8s.GetPVCAnnotations` — package-level `var getPVCAnnotations = defaultGetPVCAnnotations` pattern.

**`pkg/k8s/pvc_test.go`** — happy path using `fake.NewSimpleClientset` from `k8s.io/client-go/kubernetes/fake`. ~30 lines.

### Integration / live test

New file `test/ownership/ownership_test.go`:

1. Clean filer (existing sanity harness).
2. Fake PVC with annotations `mount-root-uid="1234", mount-root-gid="5678"`.
3. `CreateVolume` with `params["csi.storage.k8s.io/pvc/name"]="fake", ...namespace="default"`.
4. Assert returned VolumeContext has both keys.
5. `filer_pb.LookupEntry` directly against filer → assert `Attributes.{Uid==1234, Gid==5678, FileMode & 0777 == 0770}`.
6. `NodeStageVolume` with PV's volume context → succeeds.
7. `LookupEntry` again → still `1234:5678` (no regression).
8. Mutate volume context (`mountRootUid="2000"`), call NodeStage again → `LookupEntry` now `Uid==2000` (retrofit path works).

Own package, independent of sanity. Runs via `make test-ownership`.

### Manual verification after rollout

Captured in VERIFICATION.md for the phase:

1. `kubectl -n seaweedfs logs deployment/seaweedfs-csi-controller -c csi-provisioner | grep -i extra-create` — shows flag active.
2. Fresh test PVC with `uid=12345, gid=67890` → PV `volumeAttributes` shows both; debug pod stat shows `12345:67890 0770`; delete.
3. Retrofit: `kubectl patch pv <name>` + pod cycle → stat shows new ownership.
4. fsGroup-only path: pick a consumer with `fs_group` but no annotations; cycle pod; stat shows `*:<fs_group> 0770`.
5. Plex incident repro: `kubectl exec plex -- ls -la /config` shows `990:997 0770` (or `0:997 0770` without annotations). Crash impossible to recreate.
6. `weed shell fs.ls /buckets/plex-config` confirms filer source-of-truth.
7. Driver logs show `applyMountRootOwnership` log line with resolved uid/gid + UpdateEntry success.
8. All 13 consumers come up healthy after rollout.

### Out of scope for testing

- csi-sanity extensions — driver passes sanity today; our changes don't affect sanity-covered interfaces for the default case.
- Upgrade/downgrade mixed-version tests — change is backward compatible (absent annotations = no-op).

## Rollout sequence

```
1. Driver work (drivers/seaweedfs-csi-driver/)
   - Implement all Go changes
   - Unit + ownership e2e tests pass
   - Single atomic commit

2. Image build + sideload (per feedback_always_sideload_seaweedfs_images.md)
   - `make build` → three images at VERSION=v0.1.2
   - Multi-arch buildx: linux/amd64 + linux/arm64
   - scp + `sudo k3s ctr -n k8s.io images import` on hestia, heracles, nyx
   - DO NOT push to registry.brmartin.co.uk — chicken-egg

3. Verify sideloaded images on every node
   - `sudo k3s ctr -n k8s.io images list | grep v0.1.2` on all 3

4. Terraform apply — driver + provisioner flag + version bumps
   - modules-k8s/seaweedfs/csi.tf: --extra-create-metadata
   - modules-k8s/seaweedfs/variables.tf: three tag bumps
   - Expect rollouts: csi-controller Deployment, csi-node DaemonSet,
     seaweedfs-mount DaemonSet, consumer-recycler DaemonSet

5. Automatic consumer cycling
   - consumer-recycler DaemonSet (shipped 2026-04-09) cycles each pod
     on its node as the mount DaemonSet rolls
   - Each pod's next NodeStage:
     → injectVolumeMountGroup auto-derives mountRootGid from fsGroup
     → applyMountRootOwnership → filer_pb.UpdateEntry
     → mount root becomes *:<fsGroup> 0770 on filer
   - Watch: `kubectl get pods -A -w`. ~5-10 min full rollout.

6. Verify Plex fix
   - `kubectl exec -n default deploy/plex -- stat /config`
   - Expect: 0:997 (or 990:997 with annotations) drwxrwx---
   - Plex starts cleanly, no "Permission denied" on Cache

7. Consumer-module cleanup (separate commits)
   - nextcloud: delete chown init container
   - plex: optional annotations for cosmetic uid match

8. Post-rollout verification (manual steps 1-8)
```

### PVs needing `kubectl patch`

**None.** Every existing SeaweedFS-backed consumer sets `fsGroup`, so auto-derivation covers them all on pod cycle. The PV-patch retrofit mechanism stays documented as an escape hatch but is not part of the planned sequence.

### Rollback

If v0.1.2 misbehaves:

1. `terraform apply` with tags reverted to previous (`v1.4.8-split` driver+mount, `v0.1.1` recycler). **Do not** remove old image tags from nodes for at least a week.
2. Filer metadata is not rolled back — mount roots that became `0:997 0770` stay that way. Safe: old driver is happy with any perms on the root inode, and the data is correct by construction.
3. Specific entries can be reverted with `weed shell fs.chown` / `fs.chmod`.

### Commit sequencing

1. `feat(seaweedfs/csi): add mount-root ownership via PVC annotations` — all driver Go + Makefile bump.
2. `feat(seaweedfs): enable --extra-create-metadata on csi-provisioner` — one line in csi.tf.
3. `chore(seaweedfs): bump monorepo images to v0.1.2` — variables.tf only.
4. `refactor(nextcloud): drop chown init container — handled by CSI driver` — nextcloud module.
5. `feat(plex): declare mount-root ownership via PVC annotations` — media-centre module. Optional.

Commits 2+3 must apply together. 4+5 must wait for 2+3 to be rolled out. Commit 1 is independent (produces the images that 3 references).

## Non-goals

1. **Recursive chown/chmod.** Strictly root-inode only. Intra-tree ownership is workload-managed.
2. **`weed mount` fork.** Filer-side approach is strictly better. No upstream changes.
3. **Upstream PR to seaweedfs-csi-driver.** Per `project_seaweedfs_driver_monorepo_layout.md`: in-tree hard fork, never suggest upstream unless explicitly asked.
4. **`mount-root-mode` annotation.** Hardcoded `0770`. Trivial extension if needed later.
5. **Per-StorageClass defaults.** Rejected: one StorageClass only.
6. **Drift-detection controller.** Belt-and-suspenders NodeStage re-apply is the reconciliation loop.
7. **Plex Preferences.xml recovery.** Already done 2026-04-09 from restic.
8. **Gaps 9-12** (readiness probes, cont-init clobber protection, self-service restic restore, extended alerting) — belong to `2026-04-08-seaweedfs-production-readiness-notes.md`.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `filer_pb.UpdateEntry` fails during NodeStage, pod stuck ContainerCreating | Low | Fail-loud event; `weed shell fs.chown` escape hatch |
| `--extra-create-metadata` flag removed in future csi-provisioner | Very low | Pinned `csi_provisioner_image_tag`; upgrades gated on release-note review |
| Annotation key typo silently ignored | Medium | V(4) logs annotations read; e2e test catches exact keys; comments in consumer modules reference keys |
| Consumer without fsGroup stays `0:0 0750` | Low (none today) | Verification step 4 catches; handled with explicit annotations |
| New consumer author forgets fsGroup AND annotations | Medium | Same shape as forgetting securityContext. Module-template concern, not driver. |
| RWX multi-node UpdateEntry race | Very low | Idempotent with same input; filer serializes |

## Success criteria

1. Plex pod starts cleanly on fresh stage without init container, `fs_group_change_policy`, or manual chown — purely via CSI driver setting `/config` to `0:997 0770` (or `990:997 0770` with explicit annotations).
2. Nextcloud's chown init container deleted, pods come up cleanly, `stat /nc-data` shows `33:33 0770`.
3. Fresh PVC with annotations `uid=12345, gid=67890` (no matching fsGroup) → mount root owned `12345:67890 0770` on both filer (via `weed shell`) and FUSE (via `stat` in pod).
4. `kubectl patch pv` + pod cycle correctly retrofits an existing PV.
5. Unit + e2e tests pass green.
6. No regressions in any of the 13 SeaweedFS-backed consumer modules.
7. 2026-04-09 Plex crashloop cannot be reproduced by any normal operational action.

## References

- Proto-plan / context dump: `docs/superpowers/plans/2026-04-09-csi-mount-root-ownership.md`
- Related production-readiness tracker: `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`
- Memories: `project_csi_mount_root_ownership.md`, `project_seaweedfs_csi_deployment.md`, `project_seaweedfs_driver_monorepo_layout.md`, `project_seaweedfs_monorepo_versioning.md`, `feedback_always_sideload_seaweedfs_images.md`, `feedback_prefer_resilience_over_minimal_diff.md`
- Driver source: `drivers/seaweedfs-csi-driver/pkg/driver/{controllerserver.go,nodeserver.go,mounter.go,driver.go}`, `drivers/seaweedfs-csi-driver/pkg/k8s/`
- Vendored seaweedfs: `github.com/seaweedfs/seaweedfs v0.0.0-20260402004241-6213daf11812` — `weed/pb/filer_pb/{filer_client.go,filer_pb_helper.go}` for `Mkdir`/`UpdateEntry`/`LookupEntry`
- Terraform: `modules-k8s/seaweedfs/{csi.tf,csi-rbac.tf,variables.tf,storage-class.tf}`
