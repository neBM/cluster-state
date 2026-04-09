# CSI Mount-Root Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a PVC declare the desired owner of its mount-root inode via two annotations (`seaweedfs.csi.brmartin.co.uk/mount-root-uid` / `mount-root-gid`), resolved by the CSI driver and written directly to the filer via `filer_pb.Mkdir` (provisioning) and `filer_pb.UpdateEntry` (staging). Auto-derive `mountRootGid` from kubelet's `VolumeMountGroup` (fsGroup) when annotations are absent. Ship as monorepo release `v0.1.3`.

**Architecture:** Filer-authoritative. `CreateVolume` resolves PVC annotations via a new `pkg/k8s.GetPVCAnnotations` helper (enabled by the csi-provisioner `--extra-create-metadata` flag that injects `csi.storage.k8s.io/pvc/{name,namespace}` into `params`) and passes a callback to `filer_pb.Mkdir` that sets `Entry.Attributes.{Uid,Gid,FileMode}` at creation time. It also persists the resolved values into the returned `VolumeContext`, where they are carried into the PV's `spec.csi.volumeAttributes`. `NodeStageVolume` then re-applies the same attrs on every stage via `filer_pb.UpdateEntry` against the filer (belt-and-suspenders for drift + retrofit path). `NodePublishVolume`'s self-healing re-stage flow is covered for free because it calls `stageNewVolume`. No `os.Chown` through FUSE.

**Tech Stack:** Go (existing module), `k8s.io/client-go` (already imported), `github.com/seaweedfs/seaweedfs/weed/pb/filer_pb` (vendored). Terraform `kubernetes` provider in `modules-k8s/seaweedfs/`. Image build via `drivers/seaweedfs-csi-driver/Makefile` with `VERSION=v0.1.3` passed at invocation time. Sideload to all three nodes (registry is backed by SeaweedFS — chicken-egg).

**Spec reference:** `docs/superpowers/specs/2026-04-09-csi-mount-root-ownership-design.md`. Read this first — it contains the full "why", rejected alternatives, risk register, and rollback procedure. This plan is the "how".

**Version note:** The spec body says "v0.1.2, was v1.4.8-split" — that's stale. `v0.1.2` already shipped as the socket-retry release (see commit `d2e27c8`). This plan ships as **`v0.1.3`** and bumps all three monorepo images together (driver, mount, recycler) per `project_seaweedfs_monorepo_versioning.md`.

**Key memory pointers (read before starting):**
- `memory/project_seaweedfs_driver_monorepo_layout.md` — driver lives in-tree at `drivers/seaweedfs-csi-driver/`; do NOT use the external `~/Documents/Personal/projects/seaweedfs-csi-driver` clone
- `memory/project_seaweedfs_monorepo_versioning.md` — unified `v0.x.x` versioning across driver+mount+recycler
- `memory/project_csi_mount_root_ownership.md` — incident background; FUSE root inode does not receive `-map.gid` translation
- `memory/project_seaweedfs_csi_deployment.md` — custom CSI deployment context
- `memory/feedback_always_sideload_seaweedfs_images.md` — never push driver images to `registry.brmartin.co.uk` (registry is backed by SeaweedFS — chicken-egg)
- `memory/feedback_reputable_libraries.md` — use stdlib + established libs
- `memory/feedback_prefer_resilience_over_minimal_diff.md` — belt-and-suspenders is intentional here

**Incident context:** 2026-04-09 Plex crashloop, `boost::filesystem::create_directories: Permission denied` on `/config/Library/Application Support/Plex Media Server/Cache`. Root cause: `/config` was `0:0 0750`, Plex runs as uid 990 via s6-setuidgid, cannot traverse the mount root. Files inside were correctly `990:997` via existing `-map.gid` fork, but unreachable because the root inode was wrong. Recovered manually with `chown` + restic restore; this plan makes the fix durable.

---

## Task 1: Setup — branch and baseline

**Files:**
- None modified

- [ ] **Step 1: Create feature branch**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
git checkout -b feat/csi-mount-root-ownership
```

- [ ] **Step 2: Confirm baseline driver tests pass**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./pkg/... -count=1
```

Expected: `ok` (or `?` no test files) for every package. If any package already fails, stop and investigate before continuing — you need a green baseline to distinguish your failures.

- [ ] **Step 3: Confirm vendored filer_pb helpers are reachable**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go doc github.com/seaweedfs/seaweedfs/weed/pb/filer_pb Mkdir
go doc github.com/seaweedfs/seaweedfs/weed/pb/filer_pb UpdateEntry
go doc github.com/seaweedfs/seaweedfs/weed/pb/filer_pb LookupEntry
```

Expected: each prints a signature line. Verifies:
- `Mkdir(ctx, filerClient, parentDir, dirName, fn func(*Entry)) error`
- `UpdateEntry(ctx, SeaweedFilerClient, *UpdateEntryRequest) error`
- `LookupEntry(ctx, SeaweedFilerClient, *LookupDirectoryEntryRequest) (*LookupDirectoryEntryResponse, error)`

If any is missing, stop — the vendored version must be updated.

- [ ] **Step 4: Confirm client-go fake clientset is importable**

```bash
go doc k8s.io/client-go/kubernetes/fake NewSimpleClientset 2>&1 | head -5
```

Expected: `func NewSimpleClientset(objects ...runtime.Object) *Clientset`. If not, add to deps in Task 2's first step with `go get k8s.io/client-go/kubernetes/fake`.

---

## Task 2: `pkg/k8s.GetPVCAnnotations` helper — TDD

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/k8s/pvc.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/k8s/pvc_test.go`

**Design:** Matches existing `GetVolumeCapacity` pattern in `pkg/k8s/client.go:28` — in-cluster clientset, context with timeout, `get` on the namespaced resource. For testability the exported function delegates to an unexported `getPVCAnnotationsWithClient` that takes an injected clientset.

- [ ] **Step 1: Write the failing test**

Create `drivers/seaweedfs-csi-driver/pkg/k8s/pvc_test.go`:

```go
package k8s

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestGetPVCAnnotationsWithClient_Found(t *testing.T) {
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plex-config",
			Namespace: "default",
			Annotations: map[string]string{
				"seaweedfs.csi.brmartin.co.uk/mount-root-uid": "990",
				"seaweedfs.csi.brmartin.co.uk/mount-root-gid": "997",
				"unrelated.example.com/other":                 "noise",
			},
		},
	}
	client := fake.NewSimpleClientset(pvc)

	got, err := getPVCAnnotationsWithClient(context.Background(), client, "default", "plex-config")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got["seaweedfs.csi.brmartin.co.uk/mount-root-uid"] != "990" {
		t.Errorf("uid annotation: got %q, want %q", got["seaweedfs.csi.brmartin.co.uk/mount-root-uid"], "990")
	}
	if got["seaweedfs.csi.brmartin.co.uk/mount-root-gid"] != "997" {
		t.Errorf("gid annotation: got %q, want %q", got["seaweedfs.csi.brmartin.co.uk/mount-root-gid"], "997")
	}
	if got["unrelated.example.com/other"] != "noise" {
		t.Errorf("all annotations should be returned, got: %v", got)
	}
}

func TestGetPVCAnnotationsWithClient_NotFound(t *testing.T) {
	client := fake.NewSimpleClientset()
	got, err := getPVCAnnotationsWithClient(context.Background(), client, "default", "missing")
	if err == nil {
		t.Errorf("expected error for missing PVC, got nil, annotations=%v", got)
	}
}

func TestGetPVCAnnotationsWithClient_NoAnnotations(t *testing.T) {
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "bare",
			Namespace: "default",
		},
	}
	client := fake.NewSimpleClientset(pvc)
	got, err := getPVCAnnotationsWithClient(context.Background(), client, "default", "bare")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty annotations, got %v", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./pkg/k8s/... -run TestGetPVCAnnotations -v
```

Expected: `FAIL` with `undefined: getPVCAnnotationsWithClient` (and possibly `undefined: corev1`, `fake` — if so, `go mod tidy` first).

If `fake` package is missing:
```bash
go get k8s.io/client-go/kubernetes/fake@$(go list -m -f '{{.Version}}' k8s.io/client-go)
go mod tidy
```
Then re-run.

- [ ] **Step 3: Write minimal implementation**

Create `drivers/seaweedfs-csi-driver/pkg/k8s/pvc.go`:

```go
package k8s

import (
	"context"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// GetPVCAnnotations fetches a PVC by namespace/name via an in-cluster client
// and returns its annotations map. The returned map may be nil if the PVC has
// no annotations. Returns a non-nil error if the PVC cannot be fetched (e.g.
// not found, RBAC denied, network failure) — callers must decide whether to
// treat absence as fatal.
func GetPVCAnnotations(ctx context.Context, namespace, name string) (map[string]string, error) {
	client, err := newInCluster()
	if err != nil {
		return nil, err
	}
	return getPVCAnnotationsWithClient(ctx, client, namespace, name)
}

// getPVCAnnotationsWithClient is the testable seam. Any clientset implementing
// kubernetes.Interface works (real or fake). The caller's ctx is respected; we
// only impose a ceiling timeout if none was provided.
func getPVCAnnotationsWithClient(ctx context.Context, client kubernetes.Interface, namespace, name string) (map[string]string, error) {
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
	}

	pvc, err := client.CoreV1().PersistentVolumeClaims(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("get pvc %s/%s: %w", namespace, name, err)
	}
	return pvc.Annotations, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./pkg/k8s/... -run TestGetPVCAnnotations -v
```

Expected: `PASS` for all three subtests.

- [ ] **Step 5: Run full package test**

```bash
go test ./pkg/k8s/... -count=1
```

Expected: `ok` no regressions.

- [ ] **Step 6: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/k8s/pvc.go \
        drivers/seaweedfs-csi-driver/pkg/k8s/pvc_test.go \
        drivers/seaweedfs-csi-driver/go.mod \
        drivers/seaweedfs-csi-driver/go.sum
git commit -m "feat(seaweedfs/csi): add k8s.GetPVCAnnotations helper

Reads annotations from a namespaced PVC via in-cluster client. Follows
the existing GetVolumeCapacity pattern, adds a testable seam via
getPVCAnnotationsWithClient(kubernetes.Interface, ...).

Prep for mount-root ownership resolution in CreateVolume."
```

---

## Task 3: `parseOwnershipAnnotation` helper — TDD

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver_test.go`

**Design:** File-local helper that parses an annotation value to `*int32`. Returns `(nil, nil)` when the annotation is absent (caller treats as "no override"), `(nil, err)` on bad format or negative. Caller surfaces errors as `codes.InvalidArgument`.

- [ ] **Step 1: Write the failing test**

Create `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver_test.go`:

```go
package driver

import (
	"testing"
)

func TestParseOwnershipAnnotation_Absent(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil pointer for absent annotation, got %d", *got)
	}
}

func TestParseOwnershipAnnotation_Empty(t *testing.T) {
	// Empty string value must be treated identically to absent.
	got, err := parseOwnershipAnnotation(map[string]string{"k": ""}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil for empty value, got %d", *got)
	}
}

func TestParseOwnershipAnnotation_Valid(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "990"}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || *got != 990 {
		t.Errorf("expected 990, got %v", got)
	}
}

func TestParseOwnershipAnnotation_Zero(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "0"}, "k")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || *got != 0 {
		t.Errorf("expected 0, got %v", got)
	}
}

func TestParseOwnershipAnnotation_Negative(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "-1"}, "k")
	if err == nil {
		t.Errorf("expected error for negative, got nil (value=%v)", got)
	}
}

func TestParseOwnershipAnnotation_NonInteger(t *testing.T) {
	got, err := parseOwnershipAnnotation(map[string]string{"k": "990abc"}, "k")
	if err == nil {
		t.Errorf("expected error for non-integer, got nil (value=%v)", got)
	}
}

func TestParseOwnershipAnnotation_Overflow(t *testing.T) {
	// int32 max is 2147483647. 2147483648 must fail.
	got, err := parseOwnershipAnnotation(map[string]string{"k": "2147483648"}, "k")
	if err == nil {
		t.Errorf("expected overflow error, got nil (value=%v)", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./pkg/driver/... -run TestParseOwnershipAnnotation -v
```

Expected: `FAIL` with `undefined: parseOwnershipAnnotation`.

- [ ] **Step 3: Add the helper to `controllerserver.go`**

Edit `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go`. Add to the imports block (after existing `"strings"`):

```go
import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"strconv"
	"strings"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/k8s"
	"github.com/seaweedfs/seaweedfs/weed/glog"
	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
	"github.com/seaweedfs/seaweedfs/weed/s3api/s3bucket"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)
```

(`os`, `strconv`, `k8s` are new; others were already present.)

At the very bottom of the file (after `isValidVolumeCapabilities`), append:

```go
// parseOwnershipAnnotation reads a numeric uid/gid annotation from the map.
// Returns (nil, nil) when the annotation is absent or empty. Returns an error
// for non-integer, negative, or out-of-range-for-int32 values.
func parseOwnershipAnnotation(annotations map[string]string, key string) (*int32, error) {
	v, ok := annotations[key]
	if !ok || v == "" {
		return nil, nil
	}
	n, err := strconv.ParseInt(v, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("invalid annotation %s=%q: %w", key, v, err)
	}
	if n < 0 {
		return nil, fmt.Errorf("invalid annotation %s=%q: must be >= 0", key, v)
	}
	result := int32(n)
	return &result, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./pkg/driver/... -run TestParseOwnershipAnnotation -v
```

Expected: `PASS` for all seven subtests.

- [ ] **Step 5: Full-package build sanity check**

```bash
go build ./pkg/driver/...
```

Expected: no errors. If any unused-import errors on `os`/`strconv`/`k8s`, proceed to Task 4 which uses them — or temporarily suppress with `var _ = os.Chmod` etc. (Prefer: move on to Task 4 immediately, since imports will be consumed there.)

- [ ] **Step 6: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go \
        drivers/seaweedfs-csi-driver/pkg/driver/controllerserver_test.go
git commit -m "feat(seaweedfs/csi): add parseOwnershipAnnotation helper

Parses numeric uid/gid PVC annotations into *int32 with range checks.
Returns (nil, nil) on absence so callers can distinguish 'not set' from
'zero'. Used in CreateVolume to resolve mount-root ownership."
```

---

## Task 4: Resolve PVC annotations in `CreateVolume` — TDD

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go` (function `CreateVolume` at `:31`)
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver_test.go`

**Design:** CreateVolume looks up PVC annotations (when `csi.storage.k8s.io/pvc/name` + `namespace` are present in `params`, which requires the `--extra-create-metadata` flag on csi-provisioner — wired in Task 10). Parsed uid/gid are passed to `filer_pb.Mkdir` via a closure `fn` that sets `Entry.Attributes.{Uid,Gid,FileMode}` — `FileMode = 0770 | os.ModeDir` when *either* uid or gid is set. Resolved values are then persisted into `params` (which is returned as `VolumeContext` on the response) so `NodeStageVolume` can re-apply them later.

Testability seam: package-level `var getPVCAnnotations = k8s.GetPVCAnnotations`, which tests override.

- [ ] **Step 1: Write failing tests**

Append to `drivers/seaweedfs-csi-driver/pkg/driver/controllerserver_test.go`:

```go
import (
	"context"
	"testing"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Note: the file already imports "testing" from Task 3; merge import blocks.

// newTestControllerServer returns a ControllerServer whose Driver is just
// enough to make CreateVolume work in-test. Any call that reaches the filer
// will panic unless we stub it — the tests below stub both the PVC lookup
// and the Mkdir path.
func newTestControllerServer(t *testing.T) *ControllerServer {
	t.Helper()
	return &ControllerServer{
		Driver: &SeaweedFsDriver{
			RunController: true,
		},
	}
}

func TestCreateVolume_ResolvesPVCAnnotations(t *testing.T) {
	// Capture what Mkdir's fn sets, and what params the server records.
	var captured *filer_pb.Entry
	origMkdir := mkdirFunc
	mkdirFunc = func(ctx context.Context, fc filer_pb.FilerClient, parent, name string, fn func(*filer_pb.Entry)) error {
		entry := &filer_pb.Entry{Attributes: &filer_pb.FuseAttributes{}}
		if fn != nil {
			fn(entry)
		}
		captured = entry
		return nil
	}
	t.Cleanup(func() { mkdirFunc = origMkdir })

	origGet := getPVCAnnotations
	getPVCAnnotations = func(ctx context.Context, ns, n string) (map[string]string, error) {
		if ns != "default" || n != "plex-config" {
			t.Fatalf("unexpected pvc lookup: %s/%s", ns, n)
		}
		return map[string]string{
			"seaweedfs.csi.brmartin.co.uk/mount-root-uid": "990",
			"seaweedfs.csi.brmartin.co.uk/mount-root-gid": "997",
		}, nil
	}
	t.Cleanup(func() { getPVCAnnotations = origGet })

	cs := newTestControllerServer(t)
	resp, err := cs.CreateVolume(context.Background(), &csi.CreateVolumeRequest{
		Name: "plex-config",
		VolumeCapabilities: []*csi.VolumeCapability{{
			AccessType: &csi.VolumeCapability_Mount{Mount: &csi.VolumeCapability_MountVolume{}},
			AccessMode: &csi.VolumeCapability_AccessMode{Mode: csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER},
		}},
		Parameters: map[string]string{
			"csi.storage.k8s.io/pvc/name":      "plex-config",
			"csi.storage.k8s.io/pvc/namespace": "default",
		},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if captured == nil {
		t.Fatal("Mkdir fn was not invoked")
	}
	if captured.Attributes.Uid != 990 {
		t.Errorf("Uid: got %d, want 990", captured.Attributes.Uid)
	}
	if captured.Attributes.Gid != 997 {
		t.Errorf("Gid: got %d, want 997", captured.Attributes.Gid)
	}
	wantMode := uint32(0770) | uint32(os.ModeDir)
	if captured.Attributes.FileMode != wantMode {
		t.Errorf("FileMode: got 0%o, want 0%o", captured.Attributes.FileMode, wantMode)
	}

	ctx := resp.Volume.VolumeContext
	if ctx["mountRootUid"] != "990" {
		t.Errorf("volumeContext mountRootUid: got %q, want %q", ctx["mountRootUid"], "990")
	}
	if ctx["mountRootGid"] != "997" {
		t.Errorf("volumeContext mountRootGid: got %q, want %q", ctx["mountRootGid"], "997")
	}
}

func TestCreateVolume_WithoutPVCMetadataParams(t *testing.T) {
	// No csi.storage.k8s.io/pvc/* params → no lookup attempted, Mkdir fn is
	// a no-op, volumeContext has no mountRoot* keys.
	var captured *filer_pb.Entry
	origMkdir := mkdirFunc
	mkdirFunc = func(ctx context.Context, fc filer_pb.FilerClient, parent, name string, fn func(*filer_pb.Entry)) error {
		entry := &filer_pb.Entry{Attributes: &filer_pb.FuseAttributes{}}
		if fn != nil {
			fn(entry)
		}
		captured = entry
		return nil
	}
	t.Cleanup(func() { mkdirFunc = origMkdir })

	origGet := getPVCAnnotations
	getPVCAnnotations = func(ctx context.Context, ns, n string) (map[string]string, error) {
		t.Fatalf("getPVCAnnotations should not be called when pvc/* params absent")
		return nil, nil
	}
	t.Cleanup(func() { getPVCAnnotations = origGet })

	cs := newTestControllerServer(t)
	resp, err := cs.CreateVolume(context.Background(), &csi.CreateVolumeRequest{
		Name: "bare-volume",
		VolumeCapabilities: []*csi.VolumeCapability{{
			AccessType: &csi.VolumeCapability_Mount{Mount: &csi.VolumeCapability_MountVolume{}},
			AccessMode: &csi.VolumeCapability_AccessMode{Mode: csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER},
		}},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if captured == nil {
		t.Fatal("Mkdir should still have been called")
	}
	if captured.Attributes.Uid != 0 || captured.Attributes.Gid != 0 || captured.Attributes.FileMode != 0 {
		t.Errorf("expected no-op fn, got Uid=%d Gid=%d Mode=0%o",
			captured.Attributes.Uid, captured.Attributes.Gid, captured.Attributes.FileMode)
	}
	if _, ok := resp.Volume.VolumeContext["mountRootUid"]; ok {
		t.Errorf("mountRootUid should not be in volumeContext")
	}
	if _, ok := resp.Volume.VolumeContext["mountRootGid"]; ok {
		t.Errorf("mountRootGid should not be in volumeContext")
	}
}

func TestCreateVolume_InvalidUidAnnotation(t *testing.T) {
	origMkdir := mkdirFunc
	mkdirCalled := false
	mkdirFunc = func(ctx context.Context, fc filer_pb.FilerClient, parent, name string, fn func(*filer_pb.Entry)) error {
		mkdirCalled = true
		return nil
	}
	t.Cleanup(func() { mkdirFunc = origMkdir })

	origGet := getPVCAnnotations
	getPVCAnnotations = func(ctx context.Context, ns, n string) (map[string]string, error) {
		return map[string]string{
			"seaweedfs.csi.brmartin.co.uk/mount-root-uid": "not-a-number",
		}, nil
	}
	t.Cleanup(func() { getPVCAnnotations = origGet })

	cs := newTestControllerServer(t)
	_, err := cs.CreateVolume(context.Background(), &csi.CreateVolumeRequest{
		Name: "bad-uid",
		VolumeCapabilities: []*csi.VolumeCapability{{
			AccessType: &csi.VolumeCapability_Mount{Mount: &csi.VolumeCapability_MountVolume{}},
			AccessMode: &csi.VolumeCapability_AccessMode{Mode: csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER},
		}},
		Parameters: map[string]string{
			"csi.storage.k8s.io/pvc/name":      "bad-uid",
			"csi.storage.k8s.io/pvc/namespace": "default",
		},
	})
	if status.Code(err) != codes.InvalidArgument {
		t.Errorf("expected InvalidArgument, got %v", err)
	}
	if mkdirCalled {
		t.Errorf("Mkdir must not be called when annotation parse fails")
	}
}

func TestCreateVolume_GidOnlyAnnotation(t *testing.T) {
	var captured *filer_pb.Entry
	origMkdir := mkdirFunc
	mkdirFunc = func(ctx context.Context, fc filer_pb.FilerClient, parent, name string, fn func(*filer_pb.Entry)) error {
		entry := &filer_pb.Entry{Attributes: &filer_pb.FuseAttributes{}}
		if fn != nil {
			fn(entry)
		}
		captured = entry
		return nil
	}
	t.Cleanup(func() { mkdirFunc = origMkdir })

	origGet := getPVCAnnotations
	getPVCAnnotations = func(ctx context.Context, ns, n string) (map[string]string, error) {
		return map[string]string{
			"seaweedfs.csi.brmartin.co.uk/mount-root-gid": "997",
		}, nil
	}
	t.Cleanup(func() { getPVCAnnotations = origGet })

	cs := newTestControllerServer(t)
	resp, err := cs.CreateVolume(context.Background(), &csi.CreateVolumeRequest{
		Name: "gid-only",
		VolumeCapabilities: []*csi.VolumeCapability{{
			AccessType: &csi.VolumeCapability_Mount{Mount: &csi.VolumeCapability_MountVolume{}},
			AccessMode: &csi.VolumeCapability_AccessMode{Mode: csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER},
		}},
		Parameters: map[string]string{
			"csi.storage.k8s.io/pvc/name":      "gid-only",
			"csi.storage.k8s.io/pvc/namespace": "default",
		},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Gid set, Uid untouched (0 = filer preserves OS_UID)
	if captured.Attributes.Uid != 0 {
		t.Errorf("Uid should not be touched when only gid is provided, got %d", captured.Attributes.Uid)
	}
	if captured.Attributes.Gid != 997 {
		t.Errorf("Gid: got %d, want 997", captured.Attributes.Gid)
	}
	// FileMode is set whenever at least one of uid/gid is set.
	wantMode := uint32(0770) | uint32(os.ModeDir)
	if captured.Attributes.FileMode != wantMode {
		t.Errorf("FileMode: got 0%o, want 0%o", captured.Attributes.FileMode, wantMode)
	}
	if resp.Volume.VolumeContext["mountRootGid"] != "997" {
		t.Errorf("mountRootGid volumeContext: got %q, want %q", resp.Volume.VolumeContext["mountRootGid"], "997")
	}
	if _, ok := resp.Volume.VolumeContext["mountRootUid"]; ok {
		t.Errorf("mountRootUid should not be in volumeContext")
	}
}

func TestCreateVolume_PVCLookupFails(t *testing.T) {
	origMkdir := mkdirFunc
	mkdirFunc = func(ctx context.Context, fc filer_pb.FilerClient, parent, name string, fn func(*filer_pb.Entry)) error {
		t.Fatalf("Mkdir must not be called when PVC lookup fails")
		return nil
	}
	t.Cleanup(func() { mkdirFunc = origMkdir })

	origGet := getPVCAnnotations
	getPVCAnnotations = func(ctx context.Context, ns, n string) (map[string]string, error) {
		return nil, fmt.Errorf("rbac: forbidden")
	}
	t.Cleanup(func() { getPVCAnnotations = origGet })

	cs := newTestControllerServer(t)
	_, err := cs.CreateVolume(context.Background(), &csi.CreateVolumeRequest{
		Name: "lookup-fail",
		VolumeCapabilities: []*csi.VolumeCapability{{
			AccessType: &csi.VolumeCapability_Mount{Mount: &csi.VolumeCapability_MountVolume{}},
			AccessMode: &csi.VolumeCapability_AccessMode{Mode: csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER},
		}},
		Parameters: map[string]string{
			"csi.storage.k8s.io/pvc/name":      "lookup-fail",
			"csi.storage.k8s.io/pvc/namespace": "default",
		},
	})
	if status.Code(err) != codes.Internal {
		t.Errorf("expected Internal, got %v", err)
	}
}
```

Also update the imports at the top of `controllerserver_test.go` to include:
```go
import (
	"context"
	"fmt"
	"os"
	"testing"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./pkg/driver/... -run TestCreateVolume -v
```

Expected: `FAIL` — compile errors on `mkdirFunc` / `getPVCAnnotations` (package-level vars not yet defined). **This is correct — proceed to Step 3.**

- [ ] **Step 3: Modify `CreateVolume` in `controllerserver.go`**

Replace the `filer_pb.Mkdir(...)` block at `controllerserver.go:87-89` with the resolution + Mkdir-fn flow. Full replacement for lines 85-89 (existing `capacity := ...` through the `Mkdir` call):

```go
	capacity := req.GetCapacityRange().GetRequiredBytes()

	// Resolve mount-root ownership from PVC annotations (if provisioner passed pvc/*
	// metadata — requires --extra-create-metadata on csi-provisioner).
	var mountRootUid, mountRootGid *int32
	if pvcName, pvcNs := params["csi.storage.k8s.io/pvc/name"], params["csi.storage.k8s.io/pvc/namespace"]; pvcName != "" && pvcNs != "" {
		annotations, err := getPVCAnnotations(ctx, pvcNs, pvcName)
		if err != nil {
			return nil, status.Errorf(codes.Internal, "lookup pvc %s/%s: %v", pvcNs, pvcName, err)
		}
		uid, err := parseOwnershipAnnotation(annotations, "seaweedfs.csi.brmartin.co.uk/mount-root-uid")
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "%v", err)
		}
		gid, err := parseOwnershipAnnotation(annotations, "seaweedfs.csi.brmartin.co.uk/mount-root-gid")
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "%v", err)
		}
		mountRootUid, mountRootGid = uid, gid
	}

	// Mkdir fn stamps the root inode's attrs at creation so the first getattr
	// after `weed mount` returns them. No-op when nothing is resolved.
	mkdirFn := func(entry *filer_pb.Entry) {
		if entry.Attributes == nil {
			entry.Attributes = &filer_pb.FuseAttributes{}
		}
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

	if err := mkdirFunc(ctx, cs.Driver, parentDir, volumeName, mkdirFn); err != nil {
		return nil, fmt.Errorf("error creating volume: %v", err)
	}

	glog.V(4).Infof("volume created %s at %s", requestedVolumeId, volumePath)

	// Persist resolved values into VolumeContext for NodeStage to re-apply.
	if mountRootUid != nil {
		params["mountRootUid"] = strconv.FormatInt(int64(*mountRootUid), 10)
	}
	if mountRootGid != nil {
		params["mountRootGid"] = strconv.FormatInt(int64(*mountRootGid), 10)
	}
```

Now add the package-level testable seams. Near the top of `controllerserver.go`, after the `var unsafeVolumeIdChars` line:

```go
var unsafeVolumeIdChars = regexp.MustCompile(`[^-.a-zA-Z0-9]`)

// Testable seams for CreateVolume. Tests replace these with stubs.
var (
	getPVCAnnotations = k8s.GetPVCAnnotations
	mkdirFunc         = filer_pb.Mkdir
)
```

- [ ] **Step 4: Build to verify the change compiles**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go build ./pkg/driver/...
```

Expected: no errors. If you hit `cannot use filer_pb.Mkdir (... value of type func(...)) as ...`, the real signature differs from the stubbed one — copy the exact signature from `go doc github.com/seaweedfs/seaweedfs/weed/pb/filer_pb Mkdir` and retype the `mkdirFunc` var as `var mkdirFunc = filer_pb.Mkdir` with an explicit `func(...)` type if needed. (Go's `var x = y` should infer the exact type, so this usually Just Works.)

- [ ] **Step 5: Run tests to verify they pass**

```bash
go test ./pkg/driver/... -run TestCreateVolume -v
```

Expected: `PASS` for all five subtests.

- [ ] **Step 6: Run full driver package tests**

```bash
go test ./pkg/driver/... -count=1
```

Expected: `ok` — no regressions in pre-existing tests.

- [ ] **Step 7: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go \
        drivers/seaweedfs-csi-driver/pkg/driver/controllerserver_test.go
git commit -m "feat(seaweedfs/csi): resolve mount-root ownership in CreateVolume

When the csi-provisioner forwards PVC metadata (requires
--extra-create-metadata), look up the PVC's annotations
(seaweedfs.csi.brmartin.co.uk/mount-root-{uid,gid}) and pass them to
filer_pb.Mkdir via a callback that stamps Entry.Attributes at creation
time. Persist resolved values into VolumeContext so NodeStage can
re-apply them (belt-and-suspenders for drift + retrofit).

Testability: package-level 'mkdirFunc' and 'getPVCAnnotations' vars
let unit tests stub the filer and k8s API.

Malformed annotations -> codes.InvalidArgument.
PVC lookup failure -> codes.Internal.
Absent params -> no-op (backward compatible)."
```

---

## Task 5: `mounter.go` — ignoredArgs

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go:185-190`

The `mountRootUid` and `mountRootGid` entries in `volContext` must not be forwarded to `weed mount` as unknown CLI flags. Add them to `ignoredArgs`.

- [ ] **Step 1: Edit `buildMountArgs`**

Change the `ignoredArgs` map at `mounter.go:185-190`:

```go
ignoredArgs := map[string]struct{}{
    "dataLocality": {},
    "path":         {},
    "parentDir":    {},
    "volumeName":   {},
    "mountRootUid": {},
    "mountRootGid": {},
}
```

- [ ] **Step 2: Verify no existing test covers the warning path**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
grep -n "VolumeContext.*ignored" pkg/driver/mounter_test.go 2>/dev/null || echo "no test file / no existing test"
```

If `mounter_test.go` exists and covers this, adapt. Otherwise a dedicated test lives implicitly in the integration test (Task 9).

- [ ] **Step 3: Build + vet**

```bash
go build ./pkg/driver/...
go vet ./pkg/driver/...
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/mounter.go
git commit -m "feat(seaweedfs/csi): ignore mountRootUid/Gid in buildMountArgs

These are driver-internal VolumeContext keys consumed by
applyMountRootOwnership; they must not be forwarded to 'weed mount' as
CLI flags (would emit 'VolumeContext ignored' warnings)."
```

---

## Task 6: `injectVolumeMountGroup` auto-derives `mountRootGid` — TDD

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go:430-450`
- Create: `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver_test.go`

**Design:** When kubelet sets `VolumeCapability.MountVolume.VolumeMountGroup` and the PV's `volumeAttributes` does **not** already contain `mountRootGid` (either from explicit annotation or a retrofit patch), auto-populate `mountRootGid` to the mount group value. Today's 13 SeaweedFS-backed consumers all set `fsGroup`, so auto-derivation covers them all on pod cycle — no explicit annotation needed.

`mountRootUid` has no auto-derivation (CSI has no `runAsUser` equivalent at this layer).

- [ ] **Step 1: Write failing tests**

Create `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver_test.go`:

```go
package driver

import (
	"testing"

	"github.com/container-storage-interface/spec/lib/go/csi"
)

func capWithMountGroup(mg string) *csi.VolumeCapability {
	return &csi.VolumeCapability{
		AccessType: &csi.VolumeCapability_Mount{
			Mount: &csi.VolumeCapability_MountVolume{
				VolumeMountGroup: mg,
			},
		},
	}
}

func TestInjectVolumeMountGroup_AutoDerivesMountRootGid(t *testing.T) {
	ctx := injectVolumeMountGroup(capWithMountGroup("997"), map[string]string{})
	if ctx["gidMap"] != "997:0" {
		t.Errorf("gidMap: got %q, want %q", ctx["gidMap"], "997:0")
	}
	if ctx["mountRootGid"] != "997" {
		t.Errorf("mountRootGid: got %q, want %q", ctx["mountRootGid"], "997")
	}
}

func TestInjectVolumeMountGroup_PreservesExplicitMountRootGid(t *testing.T) {
	// Retrofit PV patch case: mountRootGid already set by CreateVolume
	// (or by a manual `kubectl patch pv`). Must not be overwritten.
	in := map[string]string{"mountRootGid": "33"}
	ctx := injectVolumeMountGroup(capWithMountGroup("997"), in)
	if ctx["gidMap"] != "997:0" {
		t.Errorf("gidMap: got %q, want %q", ctx["gidMap"], "997:0")
	}
	if ctx["mountRootGid"] != "33" {
		t.Errorf("mountRootGid must not be overwritten: got %q, want %q", ctx["mountRootGid"], "33")
	}
}

func TestInjectVolumeMountGroup_PreservesExplicitGidMap(t *testing.T) {
	// Existing behaviour: explicit gidMap wins.
	in := map[string]string{"gidMap": "42:7"}
	ctx := injectVolumeMountGroup(capWithMountGroup("997"), in)
	if ctx["gidMap"] != "42:7" {
		t.Errorf("gidMap must not be overwritten: got %q, want %q", ctx["gidMap"], "42:7")
	}
	// But mountRootGid still gets derived from the capability, because the
	// explicit gidMap doesn't tell us what the consumer's fsGroup intent was.
	if ctx["mountRootGid"] != "997" {
		t.Errorf("mountRootGid: got %q, want %q", ctx["mountRootGid"], "997")
	}
}

func TestInjectVolumeMountGroup_NoMountGroup(t *testing.T) {
	ctx := injectVolumeMountGroup(capWithMountGroup(""), map[string]string{})
	if _, ok := ctx["gidMap"]; ok {
		t.Errorf("gidMap should not be set when mount group is empty")
	}
	if _, ok := ctx["mountRootGid"]; ok {
		t.Errorf("mountRootGid should not be set when mount group is empty")
	}
}

func TestInjectVolumeMountGroup_NilCap(t *testing.T) {
	ctx := injectVolumeMountGroup(nil, map[string]string{"k": "v"})
	if ctx["k"] != "v" {
		t.Errorf("nil cap path must pass volContext through unchanged")
	}
}

func TestInjectVolumeMountGroup_NilVolContext(t *testing.T) {
	// Existing behaviour: nil volContext is lazy-inited when there's a mount group.
	ctx := injectVolumeMountGroup(capWithMountGroup("997"), nil)
	if ctx == nil {
		t.Fatal("volContext should be initialised")
	}
	if ctx["mountRootGid"] != "997" {
		t.Errorf("mountRootGid: got %q, want %q", ctx["mountRootGid"], "997")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./pkg/driver/... -run TestInjectVolumeMountGroup -v
```

Expected: `FAIL` — specifically `TestInjectVolumeMountGroup_AutoDerivesMountRootGid`, `_PreservesExplicitMountRootGid`, `_PreservesExplicitGidMap`, `_NilVolContext` should fail on `mountRootGid` assertions. The `_NoMountGroup` and `_NilCap` tests should already pass against today's code.

- [ ] **Step 3: Extend `injectVolumeMountGroup`**

Edit `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go` — replace the body of `injectVolumeMountGroup` (lines 430-450):

```go
// injectVolumeMountGroup extracts volume_mount_group from the CSI volume capability
// and injects it as gidMap into volContext if not already set. This wires kubelet's
// fsGroup through to the FUSE mount's -map.gid argument (translation for files
// *inside* the tree). It also auto-derives mountRootGid from the mount group
// when mountRootGid is not already set — this is the signal consumed by
// applyMountRootOwnership to stamp the filer root inode's attrs.
func injectVolumeMountGroup(cap *csi.VolumeCapability, volContext map[string]string) map[string]string {
	if cap == nil || cap.GetMount() == nil {
		return volContext
	}

	mountGroup := cap.GetMount().GetVolumeMountGroup()
	if mountGroup == "" {
		return volContext
	}

	if volContext == nil {
		volContext = make(map[string]string)
	}

	if _, ok := volContext["gidMap"]; !ok {
		volContext["gidMap"] = mountGroup + ":0"
		glog.Infof("injecting volume_mount_group %s as gidMap %s:0 (local:filer)", mountGroup, mountGroup)
	}

	// Auto-derive mountRootGid from fsGroup when not already set by an explicit
	// PVC annotation (persisted in volumeAttributes by CreateVolume) or a
	// retrofit `kubectl patch pv` flow. mountRootUid has no equivalent.
	if _, ok := volContext["mountRootGid"]; !ok {
		volContext["mountRootGid"] = mountGroup
		glog.Infof("auto-deriving mountRootGid=%s from volume_mount_group", mountGroup)
	}

	return volContext
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./pkg/driver/... -run TestInjectVolumeMountGroup -v
```

Expected: `PASS` for all six subtests.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go \
        drivers/seaweedfs-csi-driver/pkg/driver/nodeserver_test.go
git commit -m "feat(seaweedfs/csi): auto-derive mountRootGid from fsGroup

injectVolumeMountGroup now also populates volContext[\"mountRootGid\"]
from cap.Mount.VolumeMountGroup when not already set. This is the
signal consumed by applyMountRootOwnership (next commit) to stamp the
filer root inode's gid.

Explicit mountRootGid (from PVC annotation or retrofit PV patch) wins."
```

---

## Task 7: `applyMountRootOwnership` helper — TDD

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go`
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver_test.go`

**Design:** Pure helper that accepts the driver, a volumeID (full filer path like `/buckets/plex-config`), and a volContext map. Splits the volumeID into parent dir and name, opens a filer client, `LookupEntry`s the directory, mutates `Uid`/`Gid`/`FileMode`, and `UpdateEntry`s. Idempotent. Returns nil when neither `mountRootUid` nor `mountRootGid` is set (no-op).

For testability: we need a way to stub `WithFilerClient` and the filer RPCs. The simplest seam is a file-local `var` for the whole helper's filer-access function:

```go
var applyMountRootOwnershipFiler = func(driver *SeaweedFsDriver, volumeID string, mutate func(*filer_pb.Entry)) error {
    // real impl uses driver.WithFilerClient
}
```

Then `applyMountRootOwnership` becomes a thin parser that builds `mutate` and calls the seam.

- [ ] **Step 1: Write failing tests (append to `nodeserver_test.go`)**

Merge the nodeserver_test.go import block so it contains all of these
(the Task 6 block had only `testing` and `csi`):

```go
import (
	"context"
	"os"
	"testing"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
)

func TestApplyMountRootOwnership_Noop(t *testing.T) {
	called := false
	orig := applyMountRootOwnershipFiler
	applyMountRootOwnershipFiler = func(ctx context.Context, d *SeaweedFsDriver, v string, m func(*filer_pb.Entry)) error {
		called = true
		return nil
	}
	t.Cleanup(func() { applyMountRootOwnershipFiler = orig })

	err := applyMountRootOwnership(context.Background(), nil, "/buckets/x", map[string]string{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if called {
		t.Errorf("filer seam must not be called when volContext is empty")
	}
}

func TestApplyMountRootOwnership_BothSet(t *testing.T) {
	var gotEntry *filer_pb.Entry
	orig := applyMountRootOwnershipFiler
	applyMountRootOwnershipFiler = func(ctx context.Context, d *SeaweedFsDriver, v string, m func(*filer_pb.Entry)) error {
		entry := &filer_pb.Entry{Attributes: &filer_pb.FuseAttributes{Uid: 111, Gid: 222, FileMode: 0700}}
		m(entry)
		gotEntry = entry
		return nil
	}
	t.Cleanup(func() { applyMountRootOwnershipFiler = orig })

	err := applyMountRootOwnership(context.Background(), nil, "/buckets/plex-config", map[string]string{
		"mountRootUid": "990",
		"mountRootGid": "997",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotEntry.Attributes.Uid != 990 {
		t.Errorf("Uid: got %d, want 990", gotEntry.Attributes.Uid)
	}
	if gotEntry.Attributes.Gid != 997 {
		t.Errorf("Gid: got %d, want 997", gotEntry.Attributes.Gid)
	}
	wantMode := uint32(0770) | uint32(os.ModeDir)
	if gotEntry.Attributes.FileMode != wantMode {
		t.Errorf("FileMode: got 0%o, want 0%o", gotEntry.Attributes.FileMode, wantMode)
	}
}

func TestApplyMountRootOwnership_GidOnly(t *testing.T) {
	var gotEntry *filer_pb.Entry
	orig := applyMountRootOwnershipFiler
	applyMountRootOwnershipFiler = func(ctx context.Context, d *SeaweedFsDriver, v string, m func(*filer_pb.Entry)) error {
		// Seed Uid=555 so we can verify it is preserved.
		entry := &filer_pb.Entry{Attributes: &filer_pb.FuseAttributes{Uid: 555, Gid: 0, FileMode: 0}}
		m(entry)
		gotEntry = entry
		return nil
	}
	t.Cleanup(func() { applyMountRootOwnershipFiler = orig })

	err := applyMountRootOwnership(context.Background(), nil, "/buckets/x", map[string]string{"mountRootGid": "997"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotEntry.Attributes.Uid != 555 {
		t.Errorf("Uid must be preserved when only gid is provided, got %d", gotEntry.Attributes.Uid)
	}
	if gotEntry.Attributes.Gid != 997 {
		t.Errorf("Gid: got %d, want 997", gotEntry.Attributes.Gid)
	}
	wantMode := uint32(0770) | uint32(os.ModeDir)
	if gotEntry.Attributes.FileMode != wantMode {
		t.Errorf("FileMode: got 0%o, want 0%o", gotEntry.Attributes.FileMode, wantMode)
	}
}

func TestApplyMountRootOwnership_InvalidUid(t *testing.T) {
	called := false
	orig := applyMountRootOwnershipFiler
	applyMountRootOwnershipFiler = func(ctx context.Context, d *SeaweedFsDriver, v string, m func(*filer_pb.Entry)) error {
		called = true
		return nil
	}
	t.Cleanup(func() { applyMountRootOwnershipFiler = orig })

	err := applyMountRootOwnership(context.Background(), nil, "/buckets/x", map[string]string{"mountRootUid": "not-a-number"})
	if err == nil {
		t.Errorf("expected parse error, got nil")
	}
	if called {
		t.Errorf("filer seam must not be called when parsing fails")
	}
}

func TestApplyMountRootOwnership_NilAttributes(t *testing.T) {
	// Defensive: Entry.Attributes may be nil in some filer states.
	var gotEntry *filer_pb.Entry
	orig := applyMountRootOwnershipFiler
	applyMountRootOwnershipFiler = func(ctx context.Context, d *SeaweedFsDriver, v string, m func(*filer_pb.Entry)) error {
		entry := &filer_pb.Entry{Attributes: nil}
		m(entry)
		gotEntry = entry
		return nil
	}
	t.Cleanup(func() { applyMountRootOwnershipFiler = orig })

	if err := applyMountRootOwnership(context.Background(), nil, "/buckets/x", map[string]string{"mountRootGid": "997"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotEntry.Attributes == nil {
		t.Fatal("Attributes should be allocated by mutate fn")
	}
	if gotEntry.Attributes.Gid != 997 {
		t.Errorf("Gid: got %d, want 997", gotEntry.Attributes.Gid)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
go test ./pkg/driver/... -run TestApplyMountRootOwnership -v
```

Expected: `FAIL` with `undefined: applyMountRootOwnership`, `undefined: applyMountRootOwnershipFiler`.

- [ ] **Step 3: Implement the helper in `nodeserver.go`**

Add to the imports block at the top of `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go`
(`fmt`, `os`, `path`, `strconv`, `filer_pb` are new):

```go
import (
	"context"
	"fmt"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/k8s"
	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountmanager"
	"github.com/seaweedfs/seaweedfs/weed/glog"
	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"k8s.io/mount-utils"
)
```

Append at the very bottom of the file (after `injectVolumeMountGroup`):

```go
// applyMountRootOwnershipFiler is the testable seam. The real implementation
// opens a filer client and does LookupEntry + UpdateEntry; tests replace it
// with an in-memory stub that just calls the mutate fn on a fake entry.
// ctx is the caller's context so kubelet cancellations propagate to the
// filer RPCs.
var applyMountRootOwnershipFiler = func(ctx context.Context, driver *SeaweedFsDriver, volumeID string, mutate func(*filer_pb.Entry)) error {
	parentDir, name := splitVolumeIDForFiler(volumeID)

	return driver.WithFilerClient(false, func(client filer_pb.SeaweedFilerClient) error {
		resp, err := filer_pb.LookupEntry(ctx, client, &filer_pb.LookupDirectoryEntryRequest{
			Directory: parentDir,
			Name:      name,
		})
		if err != nil {
			return fmt.Errorf("lookup %s/%s: %w", parentDir, name, err)
		}
		entry := resp.Entry
		if entry == nil {
			return fmt.Errorf("lookup %s/%s returned nil entry", parentDir, name)
		}

		mutate(entry)

		return filer_pb.UpdateEntry(ctx, client, &filer_pb.UpdateEntryRequest{
			Directory: parentDir,
			Entry:     entry,
		})
	})
}

// splitVolumeIDForFiler converts a filer path volumeID into (parentDir, name)
// suitable for filer_pb.LookupEntry / UpdateEntry. Accepts legacy non-abs IDs
// by prepending /buckets (mirrors DeleteVolume's backward-compat path).
func splitVolumeIDForFiler(volumeID string) (string, string) {
	if !path.IsAbs(volumeID) {
		return "/buckets", volumeID
	}
	clean := strings.TrimRight(volumeID, "/")
	parent := path.Dir(clean)
	name := path.Base(clean)
	if parent == "" {
		parent = "/"
	}
	return parent, name
}

// applyMountRootOwnership reads mountRootUid / mountRootGid from volContext,
// parses them, and applies the result to the filer entry for the volume root
// via applyMountRootOwnershipFiler. No-op when neither key is set. Idempotent
// and safe to call on every NodeStageVolume invocation.
func applyMountRootOwnership(ctx context.Context, driver *SeaweedFsDriver, volumeID string, volContext map[string]string) error {
	uidStr, hasUid := volContext["mountRootUid"]
	gidStr, hasGid := volContext["mountRootGid"]
	if (!hasUid || uidStr == "") && (!hasGid || gidStr == "") {
		return nil
	}

	var uid, gid uint32
	if hasUid && uidStr != "" {
		n, err := strconv.ParseUint(uidStr, 10, 32)
		if err != nil {
			return fmt.Errorf("parse mountRootUid %q: %w", uidStr, err)
		}
		uid = uint32(n)
	}
	if hasGid && gidStr != "" {
		n, err := strconv.ParseUint(gidStr, 10, 32)
		if err != nil {
			return fmt.Errorf("parse mountRootGid %q: %w", gidStr, err)
		}
		gid = uint32(n)
	}

	mode := uint32(0770) | uint32(os.ModeDir)

	return applyMountRootOwnershipFiler(ctx, driver, volumeID, func(entry *filer_pb.Entry) {
		if entry.Attributes == nil {
			entry.Attributes = &filer_pb.FuseAttributes{}
		}
		if hasUid && uidStr != "" {
			entry.Attributes.Uid = uid
		}
		if hasGid && gidStr != "" {
			entry.Attributes.Gid = gid
		}
		entry.Attributes.FileMode = mode
	})
}
```

Note: the filer RPCs inherit the caller's ctx — the kubelet NodeStageVolume
deadline propagates. No local `time.Second` timeout is added here, matching
the spec's signature.

- [ ] **Step 4: Build**

```bash
go build ./pkg/driver/...
```

Expected: no errors. Common miss: `os` added but not used elsewhere in the file —
it is now used by `uint32(os.ModeDir)` below.

- [ ] **Step 5: Run tests to verify they pass**

```bash
go test ./pkg/driver/... -run TestApplyMountRootOwnership -v
```

Expected: `PASS` for all five subtests.

- [ ] **Step 6: Also run all driver-package tests to catch regressions**

```bash
go test ./pkg/driver/... -count=1
```

Expected: `ok`.

- [ ] **Step 7: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go \
        drivers/seaweedfs-csi-driver/pkg/driver/nodeserver_test.go
git commit -m "feat(seaweedfs/csi): add applyMountRootOwnership helper

Reads mountRootUid/mountRootGid from volContext, opens a filer client,
and writes the filer entry for the volume root directly via
LookupEntry + UpdateEntry with 0770|ModeDir. No FUSE round-trip.
Idempotent — safe to call on every NodeStageVolume.

Testability seam: applyMountRootOwnershipFiler package var lets tests
stub out the filer RPC path and assert on the mutated Entry directly.

Wiring into stageNewVolume in the next commit."
```

---

## Task 8: Wire `applyMountRootOwnership` into `stageNewVolume`

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go:375-401` (`stageNewVolume`)

**Design:** Call `applyMountRootOwnership` **before** `volume.Stage` so the filer entry is already correct by the time `weed mount` does its first getattr. Guard with a read-only check (rare, avoids noise). On filer-write failure, return the error — kubelet retries NodeStageVolume, pod sits in `ContainerCreating` with a clear event, operator can investigate. No silent swallow.

- [ ] **Step 1: Edit `stageNewVolume`**

Replace the body of `stageNewVolume` in `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go:375-401`:

```go
// stageNewVolume creates and stages a new volume with the given parameters.
// This is a helper method used by both NodeStageVolume and NodePublishVolume (for re-staging).
func (ns *NodeServer) stageNewVolume(ctx context.Context, volumeID, stagingTargetPath string, volContext map[string]string, readOnly bool) (*Volume, error) {
	// Apply mount-root ownership on the filer before the mount picks up attrs.
	// Skipped for read-only volumes (filer writes are wasted there, and RO
	// attr updates generate needless backend load). Passes caller's ctx so
	// kubelet NodeStageVolume deadline propagates into the filer RPCs.
	if !readOnly {
		if err := applyMountRootOwnership(ctx, ns.Driver, volumeID, volContext); err != nil {
			return nil, fmt.Errorf("apply mount-root ownership for %s: %w", volumeID, err)
		}
	}

	mounter, err := newMounter(volumeID, readOnly, ns.Driver, volContext)
	if err != nil {
		return nil, err
	}

	volume := NewVolume(volumeID, mounter, ns.Driver)
	if err := volume.Stage(ctx, stagingTargetPath); err != nil {
		return nil, err
	}

	// Apply quota if available
	if capacity, err := k8s.GetVolumeCapacity(volumeID); err == nil {
		if err := volume.Quota(capacity); err != nil {
			glog.Warningf("failed to apply quota for volume %s: %v", volumeID, err)
			// Clean up the staged mount since we're returning an error
			if unstageErr := volume.Unstage(ctx, stagingTargetPath); unstageErr != nil {
				glog.Errorf("failed to unstage volume %s after quota failure: %v", volumeID, unstageErr)
			}
			return nil, err
		}
	} else {
		glog.V(4).Infof("orchestration system is not compatible with the k8s api, error is: %s", err)
	}

	return volume, nil
}
```

- [ ] **Step 2: Build**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go build ./pkg/driver/...
```

Expected: no errors.

- [ ] **Step 3: Run full driver tests**

```bash
go test ./pkg/driver/... -count=1
```

Expected: `ok`. All unit tests still pass (we added a call to `applyMountRootOwnership` which is nil-gated on empty volContext, so existing tests that don't set `mountRoot*` keys will see a no-op).

- [ ] **Step 4: Run the whole module once more**

```bash
go test ./... -count=1
go vet ./...
```

Expected: `ok`, no vet warnings.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go
git commit -m "feat(seaweedfs/csi): apply mount-root ownership in stageNewVolume

Calls applyMountRootOwnership before volume.Stage so the filer entry
is correct by the first FUSE getattr — no post-mount chown race.

NodePublishVolume's self-healing re-stage path is covered for free
because it calls stageNewVolume.

Read-only volumes skip the write. Failures surface as codes.Internal
on NodeStageVolume, producing a clear kubelet event."
```

---

## Task 9: Integration test — `test/ownership`

**Files:**
- Create: `drivers/seaweedfs-csi-driver/test/ownership/ownership_test.go`

**Scope:** This test exercises `applyMountRootOwnership` against a live local filer (started by the existing sanity harness's setup script) to prove that `Mkdir` + `UpdateEntry` produce the expected `Entry.Attributes` for real. No kubelet, no FUSE — this is a filer-layer contract test.

**If no filer is available** in the dev environment, the test should `t.Skip` cleanly. Keep the test standalone — don't wire it into `make sanity`.

- [ ] **Step 1: Read the existing sanity harness to understand how it starts a filer**

```bash
cat /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver/test/sanity/*.go 2>&1 | head -80 || ls /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver/test/sanity/
```

Pattern match: find how `NewSeaweedFsDriver` is constructed with a filer address in-test. Adapt.

- [ ] **Step 2: Create the integration test file**

Create `drivers/seaweedfs-csi-driver/test/ownership/ownership_test.go`:

```go
// Package ownership exercises the CSI driver's mount-root ownership writes
// against a live filer. Skips when no filer address is set in the environment.
//
// Run: FILER_ADDR=localhost:8888 go test ./test/ownership/...
package ownership

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/driver"
	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
)

func newDriver(t *testing.T) *driver.SeaweedFsDriver {
	t.Helper()
	addr := os.Getenv("FILER_ADDR")
	if addr == "" {
		t.Skip("set FILER_ADDR=host:port to run ownership integration tests")
	}
	d := driver.NewSeaweedFsDriver("ownership-test", addr, "ownership-node", "", "", false)
	return d
}

func TestApplyOwnership_EndToEnd(t *testing.T) {
	d := newDriver(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Create a fresh volume directory under /buckets/ownership-<timestamp>.
	// Note: *SeaweedFsDriver implements filer_pb.FilerClient (see how
	// controllerserver.go CreateVolume calls filer_pb.Mkdir(ctx, cs.Driver,
	// ...)) so we pass `d` directly — no shim needed.
	name := "ownership-" + strings.ReplaceAll(time.Now().Format("150405.000000"), ".", "-")
	err := filer_pb.Mkdir(ctx, d, "/buckets", name, func(entry *filer_pb.Entry) {
		if entry.Attributes == nil {
			entry.Attributes = &filer_pb.FuseAttributes{}
		}
		entry.Attributes.Uid = 1234
		entry.Attributes.Gid = 5678
		entry.Attributes.FileMode = uint32(0770) | uint32(os.ModeDir)
	})
	if err != nil {
		t.Fatalf("Mkdir: %v", err)
	}

	// Verify via LookupEntry.
	var got *filer_pb.FuseAttributes
	err = d.WithFilerClient(false, func(client filer_pb.SeaweedFilerClient) error {
		resp, err := filer_pb.LookupEntry(ctx, client, &filer_pb.LookupDirectoryEntryRequest{
			Directory: "/buckets",
			Name:      name,
		})
		if err != nil {
			return err
		}
		got = resp.Entry.Attributes
		return nil
	})
	if err != nil {
		t.Fatalf("LookupEntry: %v", err)
	}
	if got.Uid != 1234 {
		t.Errorf("Uid: got %d, want 1234", got.Uid)
	}
	if got.Gid != 5678 {
		t.Errorf("Gid: got %d, want 5678", got.Gid)
	}
	wantMode := uint32(0770) | uint32(os.ModeDir)
	if got.FileMode != wantMode {
		t.Errorf("FileMode: got 0%o, want 0%o", got.FileMode, wantMode)
	}

	// Retrofit path: mutate via UpdateEntry.
	err = d.WithFilerClient(false, func(client filer_pb.SeaweedFilerClient) error {
		resp, err := filer_pb.LookupEntry(ctx, client, &filer_pb.LookupDirectoryEntryRequest{
			Directory: "/buckets",
			Name:      name,
		})
		if err != nil {
			return err
		}
		resp.Entry.Attributes.Uid = 2000
		return filer_pb.UpdateEntry(ctx, client, &filer_pb.UpdateEntryRequest{
			Directory: "/buckets",
			Entry:     resp.Entry,
		})
	})
	if err != nil {
		t.Fatalf("UpdateEntry: %v", err)
	}

	// Verify retrofit applied.
	err = d.WithFilerClient(false, func(client filer_pb.SeaweedFilerClient) error {
		resp, err := filer_pb.LookupEntry(ctx, client, &filer_pb.LookupDirectoryEntryRequest{
			Directory: "/buckets",
			Name:      name,
		})
		if err != nil {
			return err
		}
		got = resp.Entry.Attributes
		return nil
	})
	if err != nil {
		t.Fatalf("LookupEntry after retrofit: %v", err)
	}
	if got.Uid != 2000 {
		t.Errorf("retrofit Uid: got %d, want 2000", got.Uid)
	}
	if got.Gid != 5678 {
		t.Errorf("retrofit Gid: got %d, want 5678 (preserved)", got.Gid)
	}

	// Cleanup — filer_pb.Remove also takes a FilerClient, so pass `d`.
	_ = filer_pb.Remove(ctx, d, "/buckets", name, true, true, true, false, nil)
}
```

**Signature note:** This test relies on `*SeaweedFsDriver` implementing
`filer_pb.FilerClient`. That is already the case today — see
`drivers/seaweedfs-csi-driver/pkg/driver/controllerserver.go:87` where
`filer_pb.Mkdir(ctx, cs.Driver, ...)` is called the same way. If Task 1
Step 3 reported a Mkdir signature different from
`Mkdir(ctx, FilerClient, parentDir, dirName, fn func(*Entry)) error`,
stop and reconcile — do not proceed.

- [ ] **Step 3: Run the test in skip mode (no filer)**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./test/ownership/... -v
```

Expected: `SKIP: set FILER_ADDR=host:port to run ownership integration tests`.

- [ ] **Step 4: (Optional) Run the test against a live filer if one is available**

If a filer is already running on the dev machine (e.g. from the sanity harness):

```bash
FILER_ADDR=localhost:8888 go test ./test/ownership/... -v
```

Expected: `PASS`. If it fails, trace the error — most likely the `filer_pb.Mkdir` signature differs from what Task 1 Step 3 recorded, or the filer isn't actually reachable at `FILER_ADDR`.

If no filer is available, leave this step skipped and rely on the unit tests + post-rollout manual verification (Task 15).

- [ ] **Step 5: Build the whole module**

```bash
go build ./...
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add drivers/seaweedfs-csi-driver/test/ownership/
git commit -m "test(seaweedfs/csi): integration test for mount-root ownership

End-to-end filer contract test: Mkdir with attr-setting fn, then
LookupEntry + UpdateEntry retrofit path. Skipped unless FILER_ADDR
env var is set — runs on-demand against a dev filer, not in CI
(no CI filer instance today)."
```

---

## Task 10: Add `--extra-create-metadata` to csi-provisioner

**Files:**
- Modify: `modules-k8s/seaweedfs/csi.tf:104-109`

**Design:** The `csi-provisioner` sidecar is what injects `csi.storage.k8s.io/pvc/{name,namespace,uid}` into `CreateVolumeRequest.parameters` when `--extra-create-metadata` is passed. Without this flag, `CreateVolume` has no way to look up the PVC. RBAC is already sufficient (`csi-rbac.tf:66-70` grants `persistentvolumeclaims: get,list,watch,update`).

- [ ] **Step 1: Edit `csi.tf`**

At `modules-k8s/seaweedfs/csi.tf:104-109`, change:

```hcl
          args = [
            "--csi-address=$(ADDRESS)",
            "--leader-election",
            "--leader-election-namespace=${var.namespace}",
            "--http-endpoint=:9809",
          ]
```

to:

```hcl
          args = [
            "--csi-address=$(ADDRESS)",
            "--leader-election",
            "--leader-election-namespace=${var.namespace}",
            "--http-endpoint=:9809",
            "--extra-create-metadata",
          ]
```

- [ ] **Step 2: `terraform fmt` and `validate` (do NOT apply yet)**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
terraform fmt modules-k8s/seaweedfs/csi.tf
terraform -chdir=. validate
```

Expected: no format diff remaining, validation passes. If validation fails on unrelated drift, stop and resolve before touching this file.

- [ ] **Step 3: Commit (do not apply yet — apply comes after images are built)**

```bash
git add modules-k8s/seaweedfs/csi.tf
git commit -m "feat(seaweedfs): enable --extra-create-metadata on csi-provisioner

Required for CreateVolume to receive csi.storage.k8s.io/pvc/{name,namespace}
in Parameters, which the driver consumes in v0.1.3 to look up mount-root
ownership annotations on the PVC.

Existing controller RBAC (csi-rbac.tf:66-70) already grants the required
PVC get verb.

Deploy pairs with the v0.1.3 image bump — do not apply this commit in
isolation without the driver image ready, or the provisioner will attach
metadata that the old driver ignores (harmless no-op)."
```

---

## Task 11: Build and sideload `v0.1.3` images

**Files:**
- None modified (build output only)

**Design:** Per `memory/feedback_always_sideload_seaweedfs_images.md`, driver images MUST be sideloaded via `k3s ctr images import` — never pushed to `registry.brmartin.co.uk` (which is backed by SeaweedFS; chicken-egg). Multi-arch: `amd64` for `hestia`, `arm64` for `heracles` + `nyx`.

- [ ] **Step 1: Confirm you're on the feature branch with all Go changes committed**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
git status
git log --oneline -10
```

Expected: clean tree, last ~6-8 commits are the ones from Tasks 2-10.

- [ ] **Step 2: Build multi-arch images**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
docker buildx build --platform linux/amd64,linux/arm64 \
    -t chrislusf/seaweedfs-csi-driver:v0.1.3 \
    -f cmd/seaweedfs-csi-driver/Dockerfile.dev \
    --load .
```

Then separately for mount + recycler:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
    -t chrislusf/seaweedfs-mount:v0.1.3 \
    -f cmd/seaweedfs-mount/Dockerfile.dev \
    --load .

docker buildx build --platform linux/amd64,linux/arm64 \
    -t chrislusf/seaweedfs-consumer-recycler:v0.1.3 \
    -f cmd/seaweedfs-consumer-recycler/Dockerfile \
    --load .
```

**Note:** `docker buildx --load` only works for single-platform loads into the local daemon. For multi-arch you typically `--push` or save to tarballs. Use tarball output:

```bash
docker buildx build --platform linux/amd64 \
    -t chrislusf/seaweedfs-csi-driver:v0.1.3 \
    -f cmd/seaweedfs-csi-driver/Dockerfile.dev \
    -o type=docker,dest=/tmp/csi-driver-v0.1.3-amd64.tar .

docker buildx build --platform linux/arm64 \
    -t chrislusf/seaweedfs-csi-driver:v0.1.3 \
    -f cmd/seaweedfs-csi-driver/Dockerfile.dev \
    -o type=docker,dest=/tmp/csi-driver-v0.1.3-arm64.tar .
```

Repeat for `seaweedfs-mount` and `seaweedfs-consumer-recycler`. Six tarballs total in `/tmp/`.

Expected: each `docker buildx` invocation prints `Successfully tagged ...` and writes a non-empty tarball. Check sizes:

```bash
ls -lh /tmp/{csi-driver,mount,recycler}-v0.1.3-{amd64,arm64}.tar 2>/dev/null
```

- [ ] **Step 3: Sideload to hestia (amd64)**

```bash
scp /tmp/csi-driver-v0.1.3-amd64.tar /tmp/mount-v0.1.3-amd64.tar /tmp/recycler-v0.1.3-amd64.tar \
    hestia:/tmp/

ssh hestia 'sudo k3s ctr -n k8s.io images import /tmp/csi-driver-v0.1.3-amd64.tar && \
            sudo k3s ctr -n k8s.io images import /tmp/mount-v0.1.3-amd64.tar && \
            sudo k3s ctr -n k8s.io images import /tmp/recycler-v0.1.3-amd64.tar'
```

Expected: three lines like `unpacking chrislusf/seaweedfs-csi-driver:v0.1.3 (...)... done`.

- [ ] **Step 4: Sideload to heracles and nyx (arm64)**

```bash
for node in heracles nyx; do
    scp /tmp/csi-driver-v0.1.3-arm64.tar /tmp/mount-v0.1.3-arm64.tar /tmp/recycler-v0.1.3-arm64.tar \
        $node:/tmp/
    ssh $node "sudo k3s ctr -n k8s.io images import /tmp/csi-driver-v0.1.3-arm64.tar && \
               sudo k3s ctr -n k8s.io images import /tmp/mount-v0.1.3-arm64.tar && \
               sudo k3s ctr -n k8s.io images import /tmp/recycler-v0.1.3-arm64.tar"
done
```

Expected: six lines total (3 per node).

- [ ] **Step 5: Verify all three images are present on all three nodes**

```bash
for node in hestia heracles nyx; do
    echo "=== $node ==="
    ssh $node 'sudo k3s ctr -n k8s.io images list | grep v0.1.3'
done
```

Expected: each node shows three `chrislusf/seaweedfs-*:v0.1.3` entries. If any is missing, re-import that specific tarball before proceeding.

- [ ] **Step 6: Clean up local tarballs**

```bash
rm /tmp/csi-driver-v0.1.3-*.tar /tmp/mount-v0.1.3-*.tar /tmp/recycler-v0.1.3-*.tar
ssh hestia 'rm /tmp/csi-driver-v0.1.3-*.tar /tmp/mount-v0.1.3-*.tar /tmp/recycler-v0.1.3-*.tar'
ssh heracles 'rm /tmp/csi-driver-v0.1.3-*.tar /tmp/mount-v0.1.3-*.tar /tmp/recycler-v0.1.3-*.tar'
ssh nyx 'rm /tmp/csi-driver-v0.1.3-*.tar /tmp/mount-v0.1.3-*.tar /tmp/recycler-v0.1.3-*.tar'
```

- [ ] **Step 7: (No commit — this step was build + sideload only.)**

---

## Task 12: Bump image tags to `v0.1.3` in terraform

**Files:**
- Modify: `modules-k8s/seaweedfs/variables.tf:14-30`

- [ ] **Step 1: Edit the three default tags**

Change lines 14-30 of `modules-k8s/seaweedfs/variables.tf`:

```hcl
variable "csi_driver_image_tag" {
  description = "SeaweedFS CSI driver image tag"
  type        = string
  default     = "v0.1.3"
}

variable "csi_mount_image_tag" {
  description = "SeaweedFS mount image tag"
  type        = string
  default     = "v0.1.3"
}

variable "consumer_recycler_image_tag" {
  description = "SeaweedFS consumer recycler image tag"
  type        = string
  default     = "v0.1.3"
}
```

- [ ] **Step 2: `terraform plan` to preview the rollout**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
terraform plan -target=module.seaweedfs -out=/tmp/csi-v0.1.3.plan
```

Expected changes in the plan:
- `csi-controller` Deployment: image bumped
- `csi-node` DaemonSet: image bumped
- `seaweedfs-mount` DaemonSet: image bumped
- `consumer-recycler` DaemonSet: image bumped
- `csi-provisioner` sidecar: one new arg `--extra-create-metadata` (from Task 10 if that commit hasn't yet been applied — otherwise it's already in)

**Sanity check:** expect ~4 in-place updates, 0 destroys. If you see destroys of StatefulSets or PVCs, stop and investigate.

- [ ] **Step 3: Apply**

```bash
terraform apply /tmp/csi-v0.1.3.plan
```

Expected: apply completes in <2 minutes. No errors.

- [ ] **Step 4: Watch the rollout**

```bash
kubectl -n seaweedfs rollout status deployment/seaweedfs-csi-controller --timeout=5m
kubectl -n seaweedfs rollout status daemonset/seaweedfs-csi-node --timeout=5m
kubectl -n seaweedfs rollout status daemonset/seaweedfs-mount --timeout=5m
kubectl -n seaweedfs rollout status daemonset/seaweedfs-consumer-recycler --timeout=5m
```

Expected: all four rollouts complete with "successfully rolled out". If any pod is stuck `ImagePullBackOff`, verify the sideload succeeded on that node (Task 11 Step 5).

- [ ] **Step 5: Verify the new driver pods are running `v0.1.3`**

```bash
kubectl -n seaweedfs get pods -l app.kubernetes.io/name=seaweedfs-csi-controller -o jsonpath='{.items[*].spec.containers[?(@.name=="csi-plugin")].image}' | tr ' ' '\n'
kubectl -n seaweedfs get pods -l app.kubernetes.io/name=seaweedfs-csi-node -o jsonpath='{.items[*].spec.containers[?(@.name=="csi-plugin")].image}' | tr ' ' '\n'
```

Expected: every line ends with `:v0.1.3`.

- [ ] **Step 6: Verify csi-provisioner has `--extra-create-metadata`**

```bash
kubectl -n seaweedfs get deployment/seaweedfs-csi-controller -o jsonpath='{.spec.template.spec.containers[?(@.name=="csi-provisioner")].args}' | tr ',' '\n'
```

Expected: list includes `"--extra-create-metadata"`.

- [ ] **Step 7: Commit**

```bash
git add modules-k8s/seaweedfs/variables.tf
git commit -m "chore(seaweedfs): bump driver/mount/recycler to v0.1.3

Ships mount-root ownership support:
- PVC annotation resolution in CreateVolume (with --extra-create-metadata)
- applyMountRootOwnership on every NodeStageVolume via filer_pb.UpdateEntry
- Auto-derivation of mountRootGid from fsGroup"
```

---

## Task 13: Verify automatic rollout + Plex fix

**Files:**
- None modified

**Design:** The consumer-recycler DaemonSet (shipped 2026-04-09) cycles consumer pods on each node as the `seaweedfs-mount` DaemonSet rolls. Each cycled pod's next `NodeStageVolume` will (a) auto-derive `mountRootGid` from its `fsGroup` and (b) write the filer entry via `applyMountRootOwnership`. No manual pod deletion should be required.

- [ ] **Step 1: Watch consumer cycling**

```bash
kubectl get pods -A -w
```

Leave this running in a separate terminal / background task for ~5-10 minutes. You should see pods with seaweedfs-backed PVCs go `Terminating` → `ContainerCreating` → `Running` across the cluster.

Expected: no pod stuck in `CrashLoopBackOff` or `ContainerCreating` for more than a few minutes. If any pod is stuck, immediately check its events:

```bash
kubectl -n <ns> describe pod <name> | tail -30
```

- [ ] **Step 2: Verify Plex specifically**

```bash
# Plex runs in the default namespace per media-centre module
kubectl -n default get deploy plex
kubectl -n default rollout status deployment/plex --timeout=5m
kubectl -n default logs deployment/plex --tail=50
```

Expected: Plex pod is running; logs do NOT contain `boost::filesystem::create_directories: Permission denied`.

- [ ] **Step 3: Verify mount-root ownership on Plex's /config**

```bash
kubectl -n default exec deploy/plex -- stat -c '%u:%g %a %n' /config
```

Expected output: `0:997 770 /config` (since we haven't added the explicit `mount-root-uid=990` annotation yet — auto-derivation only set gid; uid is still the filer's OS_UID=0). The mode bits `770` are what matters for traversal: group `997` has read+execute, so Plex uid 990 (which has `997` as its supplementary group via `fsGroup`) can traverse.

If `stat` shows `0:0 750`, the `applyMountRootOwnership` write did not succeed. Check csi-node logs:

```bash
kubectl -n seaweedfs logs -l app.kubernetes.io/name=seaweedfs-csi-node -c csi-plugin --tail=200 | grep -i "mountRoot\|applyMountRoot"
```

Expected log line: `auto-deriving mountRootGid=997 from volume_mount_group`.

- [ ] **Step 4: Cross-check on the filer directly**

```bash
# Pick any seaweedfs-master pod
SF=$(kubectl -n seaweedfs get pod -l app.kubernetes.io/name=seaweedfs-master -o name | head -1)
kubectl -n seaweedfs exec -it $SF -- sh -c 'echo "fs.ls -l /buckets/plex-config" | weed shell'
```

Expected: the entry for `plex-config` shows gid=997. (The `weed shell fs.ls -l` output format varies by version; you're looking for the directory permissions/gid.)

- [ ] **Step 5: Scan for stuck pods across the whole cluster**

```bash
kubectl get pods -A | grep -vE 'Running|Completed'
```

Expected: only the usual noise (none, or at most expected in-progress rollouts). Any `CrashLoopBackOff` or `Error` row here is a regression — investigate.

- [ ] **Step 6: (No commit — verification only.)**

---

## Task 14: End-to-end test with explicit annotations on a fresh PVC

**Files:**
- None modified (creates and destroys a throwaway PVC)

**Design:** Exercise the "explicit annotation" happy path with a uid/gid that is neither 0 nor matches any fsGroup — proves the annotation-reading code path, not just the auto-derivation fallback.

- [ ] **Step 1: Create the test PVC**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mountroot-test
  namespace: default
  annotations:
    seaweedfs.csi.brmartin.co.uk/mount-root-uid: "12345"
    seaweedfs.csi.brmartin.co.uk/mount-root-gid: "67890"
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: seaweedfs
  resources:
    requests:
      storage: 1Gi
EOF
```

Expected: `persistentvolumeclaim/mountroot-test created`.

- [ ] **Step 2: Wait for it to bind**

```bash
kubectl -n default wait --for=jsonpath='{.status.phase}'=Bound pvc/mountroot-test --timeout=60s
kubectl -n default get pvc mountroot-test -o jsonpath='{.spec.volumeName}'
```

Expected: prints `pvc-<uuid>`.

- [ ] **Step 3: Inspect the bound PV's volumeAttributes**

```bash
PV=$(kubectl -n default get pvc mountroot-test -o jsonpath='{.spec.volumeName}')
kubectl get pv $PV -o jsonpath='{.spec.csi.volumeAttributes}' | jq .
```

Expected output contains:
```json
{
  "mountRootUid": "12345",
  "mountRootGid": "67890",
  ...
}
```

If `mountRootUid`/`mountRootGid` are missing, the annotation → CreateVolume → volumeAttributes flow is broken. Check csi-controller logs:

```bash
kubectl -n seaweedfs logs deployment/seaweedfs-csi-controller -c csi-plugin --tail=100 | grep -i mountroot
```

- [ ] **Step 4: Mount it with a debug pod and stat the root**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mountroot-debug
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: sh
    image: registry.brmartin.co.uk/library/alpine:3.20
    command: ["sh", "-c", "stat -c '%u:%g %a %n' /data && sleep 300"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: mountroot-test
EOF
```

Wait for it to run, then:

```bash
kubectl -n default wait --for=condition=Ready pod/mountroot-debug --timeout=60s
kubectl -n default logs pod/mountroot-debug
```

Expected output: `12345:67890 770 /data`.

- [ ] **Step 5: Cleanup**

```bash
kubectl -n default delete pod mountroot-debug --grace-period=0 --force
kubectl -n default delete pvc mountroot-test
```

Expected: both resources removed cleanly. The associated PV is reclaimed per the StorageClass's reclaim policy.

- [ ] **Step 6: (No commit — verification only.)**

---

## Task 15: Remove nextcloud chown init container

**Files:**
- Modify: `modules-k8s/nextcloud/main.tf` (delete chown init container block)

**Design:** Nextcloud's init container runs `chown 33:33 /nc-data && chmod 0770 /nc-data && chown 33:33 /nc-config /nc-custom-apps`. The first two operations are now handled by the CSI driver (fsGroup auto-derivation sets gid on the root inode; mode is hardcoded 0770). The chown on the other two mount roots is similarly redundant.

Add explicit annotations to the three nextcloud PVCs for declarative clarity.

- [ ] **Step 1: Read the relevant sections**

```bash
grep -n "chown\|nc-data\|persistent_volume_claim" modules-k8s/nextcloud/main.tf | head -40
```

Locate the init container block (around `:183` per the spec) and the PVC resources.

- [ ] **Step 2: Delete the init container block**

Remove the `init_container { ... }` block that executes the chown commands. Leave any other init containers (e.g. ones that generate config) untouched.

- [ ] **Step 3: Add explicit annotations to the three nextcloud PVCs**

For each of the three PVCs (`nc-data`, `nc-config`, `nc-custom-apps`), add annotations. Example for the PVC resource:

```hcl
resource "kubernetes_persistent_volume_claim_v1" "nc_data" {
  metadata {
    name      = "nc-data"
    namespace = var.namespace
    annotations = {
      "seaweedfs.csi.brmartin.co.uk/mount-root-uid" = "33"
      "seaweedfs.csi.brmartin.co.uk/mount-root-gid" = "33"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "seaweedfs"
    resources {
      requests = {
        storage = var.nc_data_size
      }
    }
  }
}
```

Apply the same pattern to `nc-config` and `nc-custom-apps`.

- [ ] **Step 4: `terraform plan`**

```bash
terraform plan -target=module.nextcloud -out=/tmp/nextcloud-chown.plan
```

Expected changes:
- Nextcloud Deployment: init container count decreases by 1
- Three PVCs: new `annotations` (+3 additions)

**Sanity check:** PVCs should show as in-place updates (annotations are mutable), NOT destroys. If any PVC is slated for destroy, STOP — that would cause data loss. Revert the annotation change on that specific PVC and investigate why terraform thinks it needs to recreate.

- [ ] **Step 5: Apply**

```bash
terraform apply /tmp/nextcloud-chown.plan
```

Expected: apply completes, nextcloud pod is re-created without the init container.

- [ ] **Step 6: Verify nextcloud is healthy**

```bash
kubectl rollout status deployment/nextcloud -n default --timeout=5m
kubectl exec -n default deployment/nextcloud -- stat -c '%u:%g %a %n' /nc-data /nc-config /nc-custom-apps
```

Expected: each path shows `33:33 770`. Nextcloud pod is in `Running` state, no crashes.

Namespace is `default` per `kubernetes.tf:188` (`module "k8s_nextcloud" { namespace = "default" }`).

- [ ] **Step 7: Commit**

```bash
git add modules-k8s/nextcloud/main.tf
git commit -m "refactor(nextcloud): drop chown init container

The CSI driver's mount-root ownership support (shipped in
v0.1.3) stamps the filer root inode with 33:33 0770 directly
from the new PVC annotations on nc-data, nc-config, and
nc-custom-apps. The chown init container is now a no-op."
```

---

## Task 16: (Optional) Declarative annotations on plex PVC

**Files:**
- Modify: `modules-k8s/media-centre/main.tf` (plex-config PVC)

**Design:** The plex PVC already works via fsGroup auto-derivation (gid only → `0:997 0770`). Adding explicit annotations makes the ownership declarative and sets uid=990 to match Plex's s6-setuidgid, a cosmetic improvement that produces `990:997 0770`.

This task is OPTIONAL — skip if Task 13's verification showed plex is already healthy and the cluster is under a freeze.

- [ ] **Step 1: Locate the plex-config PVC**

```bash
grep -n "plex-config\|persistent_volume_claim" modules-k8s/media-centre/main.tf
```

- [ ] **Step 2: Add annotations**

Add to the PVC's `metadata` block:

```hcl
annotations = {
  "seaweedfs.csi.brmartin.co.uk/mount-root-uid" = "990"
  "seaweedfs.csi.brmartin.co.uk/mount-root-gid" = "997"
}
```

- [ ] **Step 3: `terraform plan`**

```bash
terraform plan -target=module.media-centre -out=/tmp/plex-annot.plan
```

Expected: plex-config PVC shows annotations added (in-place update). Plex deployment is NOT recreated unless some other unrelated drift exists. If plex Deployment is slated for replace, investigate — it should be untouched.

- [ ] **Step 4: Apply**

```bash
terraform apply /tmp/plex-annot.plan
```

Annotations are mutable on a bound PVC, but the CSI driver does NOT re-read them on existing bound PVs (CreateVolume already completed). The annotations will affect any *future* rebind but won't trigger a mount-root update on the existing PV. To apply the change immediately, either:

(a) Patch the PV's volumeAttributes directly:
```bash
PV=$(kubectl -n default get pvc plex-config -o jsonpath='{.spec.volumeName}')
kubectl patch pv $PV --type=merge -p '{"spec":{"csi":{"volumeAttributes":{"mountRootUid":"990","mountRootGid":"997"}}}}'
kubectl -n default delete pod -l app=plex
```

(b) Or skip — the gid is already right via auto-derivation, and uid=990 is cosmetic.

- [ ] **Step 5: Verify**

```bash
kubectl -n default exec deploy/plex -- stat -c '%u:%g %a %n' /config
```

Expected (if you did Step 4a): `990:997 770 /config`. Without the patch it stays `0:997 770` which is also fine (Plex traverses via its `997` group).

- [ ] **Step 6: Commit**

```bash
git add modules-k8s/media-centre/main.tf
git commit -m "feat(plex): declare mount-root ownership via PVC annotations

Cosmetic uid alignment with Plex's s6-setuidgid uid 990. Existing
PVs keep their current 0:997 until patched explicitly — gid-only
auto-derivation already covered functional traversal."
```

---

## Task 17: Final verification pass against success criteria

**Files:**
- None modified

Run through every item in the spec's "Success criteria" section.

- [ ] **Step 1: Plex starts cleanly without an init container**

```bash
kubectl -n default get deploy plex -o jsonpath='{.spec.template.spec.initContainers[*].name}'
# (Plex never had a chown init container — this is a sanity check, expect empty or an unrelated init.)
kubectl -n default logs deployment/plex --tail=100 | grep -i 'permission denied' || echo OK
```

Expected: no permission denied errors.

- [ ] **Step 2: Nextcloud has no chown init container and is healthy**

```bash
kubectl -n default get deploy nextcloud -o jsonpath='{.spec.template.spec.initContainers[*].command}'
# Should no longer list `chown 33:33 ...`
kubectl -n default exec deploy/nextcloud -- stat -c '%u:%g %a' /nc-data
# Expect: 33:33 770
```

- [ ] **Step 3: Fresh PVC with non-matching uid/gid works**

Already covered by Task 14. If you want to re-run the full cycle:
```bash
# repeat Task 14 Steps 1-5
```

- [ ] **Step 4: Retrofit via `kubectl patch pv` works**

Use a throwaway PVC so no real consumer is cycled. This repros the retrofit
path without risk to production workloads.

```bash
# 1. Create a PVC with gid=5000 and a debug pod that mounts it.
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: retrofit-test
  namespace: default
  annotations:
    seaweedfs.csi.brmartin.co.uk/mount-root-gid: "5000"
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: seaweedfs
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: retrofit-debug
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: sh
    image: registry.brmartin.co.uk/library/alpine:3.20
    command: ["sh", "-c", "stat -c '%g' /data && sleep 600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: retrofit-test
EOF

kubectl -n default wait --for=condition=Ready pod/retrofit-debug --timeout=60s
kubectl -n default logs pod/retrofit-debug   # expect 5000

# 2. Patch the bound PV's volumeAttributes and cycle the pod.
PV=$(kubectl -n default get pvc retrofit-test -o jsonpath='{.spec.volumeName}')
kubectl patch pv $PV --type=merge -p '{"spec":{"csi":{"volumeAttributes":{"mountRootGid":"9999"}}}}'
kubectl -n default delete pod retrofit-debug --grace-period=0 --force

# 3. Recreate the pod and verify the new gid lands on the mount root.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: retrofit-debug
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: sh
    image: registry.brmartin.co.uk/library/alpine:3.20
    command: ["sh", "-c", "stat -c '%g' /data && sleep 600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: retrofit-test
EOF

kubectl -n default wait --for=condition=Ready pod/retrofit-debug --timeout=60s
kubectl -n default logs pod/retrofit-debug   # expect 9999 — retrofit succeeded

# 4. Cleanup.
kubectl -n default delete pod retrofit-debug --grace-period=0 --force
kubectl -n default delete pvc retrofit-test
```

Expected: first log shows `5000`, second shows `9999`. If the second
still shows `5000`, `applyMountRootOwnership` is not being called on
re-stage — check csi-node logs for `applyMountRoot` / `UpdateEntry`
entries.

- [ ] **Step 5: Unit + e2e tests green**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state/drivers/seaweedfs-csi-driver
go test ./... -count=1
```

Expected: `ok` for every package. The ownership integration test skips without `FILER_ADDR` — that's fine.

- [ ] **Step 6: No regressions in any of the 13 SeaweedFS consumers**

```bash
kubectl get pods -A -l 'app.kubernetes.io/component in (plex,nextcloud,gitlab,postfix,dovecot,overseerr,sonarr,radarr)' -o wide 2>/dev/null | head -30
kubectl get pods -A | grep -vE 'Running|Completed|NAMESPACE'
```

Expected: the second command returns nothing (no stuck or failing pods).

- [ ] **Step 7: 2026-04-09 Plex crashloop cannot be reproduced**

```bash
kubectl -n default delete pod -l app=plex
kubectl -n default wait --for=condition=Ready pod -l app=plex --timeout=5m
kubectl -n default logs deploy/plex --tail=30
```

Expected: Plex comes back healthy within a minute, logs show normal startup (no "Permission denied" on Cache).

- [ ] **Step 8: (No commit — verification only.)**

---

## Task 18: Update memory + mark spec as superseded

**Files:**
- Modify: `memory/MEMORY.md` (update the mount-root ownership entry)
- Modify: `memory/project_csi_mount_root_ownership.md` (mark as shipped)

- [ ] **Step 1: Update the memory entry**

Rewrite `/home/ben/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/project_csi_mount_root_ownership.md`:

```markdown
---
name: CSI mount-root ownership — shipped v0.1.3
description: SeaweedFS CSI driver stamps filer root inode with uid/gid via PVC annotations + fsGroup auto-derivation; shipped 2026-04-09 as v0.1.3
type: project
---

**Shipped 2026-04-09 as v0.1.3.**

Mechanism:
- PVC annotations `seaweedfs.csi.brmartin.co.uk/mount-root-{uid,gid}` resolved in CreateVolume (via `--extra-create-metadata` on csi-provisioner + k8s.GetPVCAnnotations).
- CreateVolume passes a fn to `filer_pb.Mkdir` that stamps Entry.Attributes.{Uid,Gid,FileMode=0770|ModeDir}.
- Persisted into PV.spec.csi.volumeAttributes for NodeStage to re-apply.
- NodeStage's `applyMountRootOwnership` does filer_pb.LookupEntry + UpdateEntry — idempotent, self-healing for drift.
- `injectVolumeMountGroup` auto-derives mountRootGid from fsGroup if not explicitly set — every consumer with fsGroup benefits on first pod cycle after upgrade.

Fixes:
- 2026-04-09 Plex crashloop (`/config` was 0:0 0750, Plex uid 990 couldn't traverse).
- Eliminates chown init containers for new SeaweedFS-backed workloads.
- Nextcloud's chown init container deleted 2026-04-09.

**Why:** proto-plan's os.Chown(stagingTargetPath) approach was rejected in favour of filer-authoritative writes — no FUSE round-trip, no race window, same LOC.

**How to apply:** any new non-root workload should set fsGroup (will auto-derive gid) or set both annotations explicitly. Retrofit via `kubectl patch pv <name> --type=merge -p '{"spec":{"csi":{"volumeAttributes":{"mountRootUid":"X","mountRootGid":"Y"}}}}'` + pod cycle.
```

Update the matching index line in `memory/MEMORY.md`:

```markdown
- [project_csi_mount_root_ownership.md](project_csi_mount_root_ownership.md) - SHIPPED v0.1.3 2026-04-09: CSI driver stamps filer root inode via PVC annotations + fsGroup auto-derivation
```

- [ ] **Step 2: (Memory files live in ~/.claude/projects/..., not in the repo — no git commit needed.)**

- [ ] **Step 3: Update the spec's status header**

Edit `docs/superpowers/specs/2026-04-09-csi-mount-root-ownership-design.md` line 4:

```markdown
**Status:** SHIPPED 2026-04-09 as v0.1.3
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-04-09-csi-mount-root-ownership-design.md
git commit -m "docs(seaweedfs): mark mount-root ownership spec as shipped"
```

---

## Task 19: Final commit sequencing check + PR prep

**Files:**
- None modified

- [ ] **Step 1: Review commit history on the branch**

```bash
git log --oneline main..HEAD
```

Expected sequence (roughly — exact order may vary by build/apply phasing):
```
docs(seaweedfs): mark mount-root ownership spec as shipped
feat(plex): declare mount-root ownership via PVC annotations      (optional, Task 16)
refactor(nextcloud): drop chown init container                     (Task 15)
chore(seaweedfs): bump driver/mount/recycler to v0.1.3              (Task 12)
feat(seaweedfs): enable --extra-create-metadata on csi-provisioner (Task 10)
test(seaweedfs/csi): integration test for mount-root ownership    (Task 9)
feat(seaweedfs/csi): apply mount-root ownership in stageNewVolume (Task 8)
feat(seaweedfs/csi): add applyMountRootOwnership helper           (Task 7)
feat(seaweedfs/csi): auto-derive mountRootGid from fsGroup        (Task 6)
feat(seaweedfs/csi): ignore mountRootUid/Gid in buildMountArgs    (Task 5)
feat(seaweedfs/csi): resolve mount-root ownership in CreateVolume (Task 4)
feat(seaweedfs/csi): add parseOwnershipAnnotation helper          (Task 3)
feat(seaweedfs/csi): add k8s.GetPVCAnnotations helper             (Task 2)
```

- [ ] **Step 2: Sanity-check that every test/build passes on main integration**

```bash
cd drivers/seaweedfs-csi-driver
go build ./...
go test ./... -count=1
go vet ./...
cd /home/ben/Documents/Personal/projects/iac/cluster-state
terraform fmt -check modules-k8s/seaweedfs/
terraform validate
```

Expected: all clean.

- [ ] **Step 3: (Optional) Push and open PR per `gsd:ship` workflow**

```bash
git push -u origin feat/csi-mount-root-ownership
# Then use gsd:ship or gh pr create to open the PR.
```

Do not force-push. Do not merge until a human reviews.

---

## Notes for the implementing agent

- **Vendored signature drift:** `filer_pb.Mkdir`, `UpdateEntry`, `LookupEntry` signatures were verified in Task 1 Step 3. If your `go doc` output differs from what the code assumes, stop and reconcile — don't guess.
- **Image sideload is not optional.** Pushing to `registry.brmartin.co.uk` creates a chicken-egg dependency with SeaweedFS itself. See `memory/feedback_always_sideload_seaweedfs_images.md`.
- **Do NOT refactor:** the spec explicitly rejects per-service StorageClasses, `os.Chown` on the staging target, and recursive chown. If you find yourself reaching for any of those, re-read the spec's "Rejected alternatives" table.
- **Commit granularity:** Keep Go commits small (one per task). Terraform commits stand alone so they can be reverted without rewinding Go work.
- **Memory files are outside the repo.** `memory/*.md` edits in Task 18 go under `~/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/` — no git commit for those.
- **Don't delete the proto-plan from git history.** The previous version of this file (the 2026-04-09 context dump) is preserved in commit `6728e3c`. Keep the spec's cross-reference to it intact.
