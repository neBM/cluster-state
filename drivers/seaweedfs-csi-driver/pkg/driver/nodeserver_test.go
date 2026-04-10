package driver

import (
	"context"
	"os"
	"testing"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
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

// applyMountRootOwnershipKernel issues os.Chown + os.Chmod on the mounted
// staging path so weed mount's setattr handler (weedfs_attr.go:107-123,
// NodeId==1 branch) updates its in-memory wfs.option.MountUid/Gid/Mode. This
// is the second layer of the mount-root ownership fix: v0.1.4 corrects the
// filer-side entry, but weed mount NEVER consults the filer for the root
// inode — it returns option.MountUid/Gid/Mode unconditionally from
// weedfs.go:362-373. The only way to update those fields from outside weed
// mount is via a FUSE setattr on NodeId==1.

type kernelCall struct {
	chownCalled bool
	chownPath   string
	chownUid    int
	chownGid    int
	chmodCalled bool
	chmodPath   string
	chmodMode   os.FileMode
}

func stubKernelSeams(t *testing.T, chownErr, chmodErr error) *kernelCall {
	t.Helper()
	call := &kernelCall{}
	origChown, origChmod := chownFunc, chmodFunc
	chownFunc = func(path string, uid, gid int) error {
		call.chownCalled = true
		call.chownPath = path
		call.chownUid = uid
		call.chownGid = gid
		return chownErr
	}
	chmodFunc = func(path string, mode os.FileMode) error {
		call.chmodCalled = true
		call.chmodPath = path
		call.chmodMode = mode
		return chmodErr
	}
	t.Cleanup(func() {
		chownFunc = origChown
		chmodFunc = origChmod
	})
	return call
}

func TestApplyMountRootOwnershipKernel_Noop(t *testing.T) {
	call := stubKernelSeams(t, nil, nil)

	if err := applyMountRootOwnershipKernel("/staging/target", map[string]string{}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if call.chownCalled {
		t.Errorf("chown must not be called when volContext is empty")
	}
	if call.chmodCalled {
		t.Errorf("chmod must not be called when volContext is empty")
	}
}

func TestApplyMountRootOwnershipKernel_BothSet(t *testing.T) {
	call := stubKernelSeams(t, nil, nil)

	if err := applyMountRootOwnershipKernel("/staging/target", map[string]string{
		"mountRootUid": "33333",
		"mountRootGid": "44444",
	}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !call.chownCalled {
		t.Fatal("chown must be called")
	}
	if call.chownPath != "/staging/target" {
		t.Errorf("chown path: got %q, want %q", call.chownPath, "/staging/target")
	}
	if call.chownUid != 33333 {
		t.Errorf("chown uid: got %d, want 33333", call.chownUid)
	}
	if call.chownGid != 44444 {
		t.Errorf("chown gid: got %d, want 44444", call.chownGid)
	}
	if !call.chmodCalled {
		t.Fatal("chmod must be called")
	}
	if call.chmodMode != 0770 {
		t.Errorf("chmod mode: got 0%o, want 0770", call.chmodMode)
	}
}

func TestApplyMountRootOwnershipKernel_GidOnly(t *testing.T) {
	call := stubKernelSeams(t, nil, nil)

	if err := applyMountRootOwnershipKernel("/staging/target", map[string]string{"mountRootGid": "44444"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !call.chownCalled {
		t.Fatal("chown must be called")
	}
	// Per os.Chown convention, -1 means "don't change".
	if call.chownUid != -1 {
		t.Errorf("chown uid: got %d, want -1 (no-change)", call.chownUid)
	}
	if call.chownGid != 44444 {
		t.Errorf("chown gid: got %d, want 44444", call.chownGid)
	}
	if !call.chmodCalled {
		t.Fatal("chmod must be called even when only gid is set (to stamp 0770)")
	}
}

func TestApplyMountRootOwnershipKernel_UidOnly(t *testing.T) {
	call := stubKernelSeams(t, nil, nil)

	if err := applyMountRootOwnershipKernel("/staging/target", map[string]string{"mountRootUid": "33333"}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if call.chownUid != 33333 {
		t.Errorf("chown uid: got %d, want 33333", call.chownUid)
	}
	if call.chownGid != -1 {
		t.Errorf("chown gid: got %d, want -1 (no-change)", call.chownGid)
	}
}

func TestApplyMountRootOwnershipKernel_InvalidUid(t *testing.T) {
	call := stubKernelSeams(t, nil, nil)

	err := applyMountRootOwnershipKernel("/staging/target", map[string]string{"mountRootUid": "not-a-number"})
	if err == nil {
		t.Fatal("expected parse error, got nil")
	}
	if call.chownCalled {
		t.Errorf("chown must not be called when parsing fails")
	}
	if call.chmodCalled {
		t.Errorf("chmod must not be called when parsing fails")
	}
}

func TestApplyMountRootOwnershipKernel_ChownError(t *testing.T) {
	call := stubKernelSeams(t, os.ErrPermission, nil)

	err := applyMountRootOwnershipKernel("/staging/target", map[string]string{"mountRootUid": "33333", "mountRootGid": "44444"})
	if err == nil {
		t.Fatal("expected chown error to propagate")
	}
	if call.chmodCalled {
		t.Errorf("chmod must not be called when chown fails")
	}
}

func TestApplyMountRootOwnershipKernel_ChmodError(t *testing.T) {
	stubKernelSeams(t, nil, os.ErrPermission)

	err := applyMountRootOwnershipKernel("/staging/target", map[string]string{"mountRootUid": "33333", "mountRootGid": "44444"})
	if err == nil {
		t.Fatal("expected chmod error to propagate")
	}
}
