package driver

import (
	"context"
	"errors"
	"os"
	"path/filepath"
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

// TestNewNodeServer_DoesNotWipeCacheDir is a regression test for the csi-node
// cache-wipe bug that violated the v1.4.8-split architecture guarantee.
//
// Prior to this fix, NewNodeServer unconditionally called
// removeDirContent(driver.CacheDir) on every startup. In the pre-split world
// weed mount processes lived inside the same pod as the csi-node, so coupling
// cache lifetime to csi-node lifetime was safe. After the split, weed mount
// processes run in a separate seaweedfs-mount DaemonSet but still share the
// cache directory via a node hostPath. Wiping the cache on csi-node startup
// therefore pulled the LevelDB metadata store out from under live mount
// processes, producing EIO on every readdir/createFile until the mount pod
// was also restarted and its consumers were cycled. Observed in prod on
// 2026-04-10 against Plex's config PVC on hestia.
func TestNewNodeServer_DoesNotWipeCacheDir(t *testing.T) {
	cacheDir := t.TempDir()

	// Populate with contents that mirror a real weed mount per-volume cache:
	// /var/cache/seaweedfs/<volume-hash>/<leveldb-name>/meta/<logfile>
	volumeHash := filepath.Join(cacheDir, "a7d4b8dfeed099213573a729eb836ca9bb6f0e8b2d1f374f8b59a9b356ccdb73")
	metaDir := filepath.Join(volumeHash, "be7a760f", "meta")
	if err := os.MkdirAll(metaDir, 0755); err != nil {
		t.Fatalf("prep cache dir: %v", err)
	}
	logFile := filepath.Join(metaDir, "000002.log")
	if err := os.WriteFile(logFile, []byte("fake-leveldb-wal"), 0644); err != nil {
		t.Fatalf("prep log file: %v", err)
	}

	driver := &SeaweedFsDriver{CacheDir: cacheDir}
	if ns := NewNodeServer(driver); ns == nil {
		t.Fatal("NewNodeServer returned nil")
	}

	// The file MUST still exist. NewNodeServer must never wipe a cache dir
	// that may be backing a live weed mount process in the split DaemonSet.
	if _, err := os.Stat(logFile); err != nil {
		t.Errorf("NewNodeServer wiped cache file %s: %v", logFile, err)
	}
	data, err := os.ReadFile(logFile)
	if err != nil {
		t.Errorf("reading cache file after NewNodeServer: %v", err)
	}
	if string(data) != "fake-leveldb-wal" {
		t.Errorf("cache file contents altered: got %q, want %q", string(data), "fake-leveldb-wal")
	}
}

// TestNodeUnstageVolume_NotFound_DelegatesToMountService is a regression test
// for the secondary cache-wipe bug: when ns.volumes does NOT have the volume
// (typically because csi-node restarted between stage and unstage), the old
// code called CleanupVolumeResources directly, wiping the per-volume cache
// dir under the still-running weed mount process in the mount DaemonSet.
//
// The fix delegates to the mount service via a testable seam
// (delegateUnmountToService). The mount service is authoritative: if it has
// the volume tracked, it stops the weed mount process and cleans the dir; if
// not, it is a no-op. Either way the csi-node must NOT wipe the cache dir
// locally.
func TestNodeUnstageVolume_NotFound_DelegatesToMountService(t *testing.T) {
	cacheDir := t.TempDir()
	volumeID := "pvc-test-cache-survive"

	// Create the per-volume cache dir exactly where GetCacheDir computes it,
	// so any code path that calls CleanupVolumeResources (the bug) would wipe
	// it. Populate with a fake LevelDB log file that must survive.
	volumeCacheDir := GetCacheDir(cacheDir, volumeID)
	metaDir := filepath.Join(volumeCacheDir, "be7a760f", "meta")
	if err := os.MkdirAll(metaDir, 0755); err != nil {
		t.Fatalf("prep cache dir: %v", err)
	}
	logFile := filepath.Join(metaDir, "000002.log")
	if err := os.WriteFile(logFile, []byte("fake-leveldb-wal"), 0644); err != nil {
		t.Fatalf("prep log file: %v", err)
	}

	// Stub the delegate seam so the test doesn't dial a unix socket.
	origDelegate := delegateUnmountToService
	var delegateCalls int
	var delegateVolumeID string
	delegateUnmountToService = func(ctx context.Context, driver *SeaweedFsDriver, vid string) error {
		delegateCalls++
		delegateVolumeID = vid
		return nil
	}
	defer func() { delegateUnmountToService = origDelegate }()

	ns := &NodeServer{
		Driver:        &SeaweedFsDriver{CacheDir: cacheDir},
		volumeMutexes: NewKeyMutex(),
	}

	// Non-existent staging target: mount.CleanupMountPoint is a no-op; its
	// error is already ignored by the production code.
	stagingPath := filepath.Join(t.TempDir(), "staging")

	if _, err := ns.NodeUnstageVolume(context.Background(), &csi.NodeUnstageVolumeRequest{
		VolumeId:          volumeID,
		StagingTargetPath: stagingPath,
	}); err != nil {
		t.Fatalf("NodeUnstageVolume returned error: %v", err)
	}

	// The mount service MUST have been notified so it can stop any live
	// weed mount process the csi-node no longer remembers.
	if delegateCalls != 1 {
		t.Errorf("delegateUnmountToService called %d times, want 1", delegateCalls)
	}
	if delegateVolumeID != volumeID {
		t.Errorf("delegateUnmountToService called with %q, want %q", delegateVolumeID, volumeID)
	}

	// The cache dir MUST still be intact — the weed mount process may still
	// be running. Cleanup is the mount service's job, not ours.
	if _, err := os.Stat(logFile); err != nil {
		t.Errorf("NodeUnstageVolume wiped cache file %s: %v", logFile, err)
	}
}

// publishRequestForTest builds a minimal NodePublishVolumeRequest suitable
// for NodePublishVolume unit tests. The capability is the common case
// (SINGLE_NODE_WRITER, filesystem mount, no mount-group fsGroup).
func publishRequestForTest(volumeID, stagingTargetPath, targetPath string) *csi.NodePublishVolumeRequest {
	return &csi.NodePublishVolumeRequest{
		VolumeId:          volumeID,
		StagingTargetPath: stagingTargetPath,
		TargetPath:        targetPath,
		VolumeCapability: &csi.VolumeCapability{
			AccessType: &csi.VolumeCapability_Mount{
				Mount: &csi.VolumeCapability_MountVolume{},
			},
			AccessMode: &csi.VolumeCapability_AccessMode{
				Mode: csi.VolumeCapability_AccessMode_SINGLE_NODE_WRITER,
			},
		},
	}
}

// TestNodePublishVolume_WarmCacheUnhealthyStaging_InvalidatesAndReStages is a
// regression test for the v0.1.7 SIGKILL self-heal gap.
//
// Background: in v0.1.7, the mount-service goroutine correctly detaches a
// dead weed mount process from its m.mounts map via onExit (Bug B). However,
// the csi-node's own ns.volumes in-memory cache is independent from the
// mount-service and is NOT invalidated when a weed mount process dies.
// Consequence: the next NodePublishVolume for that volume hits the warm
// cache, takes the fast path, and blindly bind-mounts the (now dead) staging
// path to the new pod's target path. The bind mount succeeds at the kernel
// level — but every subsequent I/O returns EACCES / EIO because the
// underlying FUSE daemon is gone. Observed in prod on 2026-04-10 against
// laurens-dissertation-archive-sw on nyx after a deliberate SIGKILL test.
//
// The fix: on NodePublishVolume, when the cache has a warm entry, also run
// isStagingPathHealthy against the staging path. If unhealthy, invalidate
// the cache entry and drop through to the existing self-heal re-stage path.
//
// This test asserts two things:
//  1. The re-stage seam IS called (proving the drop-through happened).
//  2. The stale cache entry IS removed from ns.volumes.
//
// Before the fix: stagerCalls would be 0 because the cache-hit fast path
// short-circuits past the re-stage branch entirely.
func TestNodePublishVolume_WarmCacheUnhealthyStaging_InvalidatesAndReStages(t *testing.T) {
	// Force isStagingPathHealthy to report unhealthy so we don't have to
	// engineer a real dead FUSE mount in a unit test.
	origIsHealthy := isStagingPathHealthy
	isStagingPathHealthy = func(stagingPath string) bool { return false }
	t.Cleanup(func() { isStagingPathHealthy = origIsHealthy })

	// Stub the stage seam so we never dial a real mount service. Record
	// whether the re-stage branch fired and with what volumeID.
	origStager := stageNewVolumeFunc
	var stagerCalls int
	var stagerVolumeID string
	stageNewVolumeFunc = func(ns *NodeServer, ctx context.Context, volumeID, stagingTargetPath string, volContext map[string]string, readOnly bool) (*Volume, error) {
		stagerCalls++
		stagerVolumeID = volumeID
		// Return an error so NodePublishVolume short-circuits before
		// trying to dial a real bind mount in Volume.Publish.
		return nil, errors.New("stub stageNewVolumeFunc: re-stage path fired")
	}
	t.Cleanup(func() { stageNewVolumeFunc = origStager })

	// t.TempDir() gives a real dir that exists but is NOT a mount point,
	// which cleanupStaleStagingPath can os.RemoveAll safely.
	stagingTargetPath := t.TempDir()
	targetPath := filepath.Join(t.TempDir(), "target")
	volumeID := "/buckets/pvc-test-sigkill-gap"

	ns := &NodeServer{
		Driver:        &SeaweedFsDriver{},
		volumeMutexes: NewKeyMutex(),
	}
	// Warm the cache: pretend csi-node already staged this volume. We use
	// rebuildVolumeFromStaging to construct a plausible Volume without
	// needing a real mounter / unmounter.
	ns.volumes.Store(volumeID, ns.rebuildVolumeFromStaging(volumeID, stagingTargetPath))

	_, err := ns.NodePublishVolume(context.Background(), publishRequestForTest(volumeID, stagingTargetPath, targetPath))

	// We deliberately stubbed the stager to fail, so an error is expected.
	// The point of this test is NOT the error itself but that we TOOK the
	// re-stage path instead of the cache-hit fast path.
	if err == nil {
		t.Fatal("expected error from stub stageNewVolumeFunc; got nil (fast path was taken)")
	}
	if stagerCalls != 1 {
		t.Errorf("stageNewVolumeFunc called %d times, want 1 — cache-hit fast path must NOT skip self-heal when staging is unhealthy", stagerCalls)
	}
	if stagerVolumeID != volumeID {
		t.Errorf("stageNewVolumeFunc called with volumeID %q, want %q", stagerVolumeID, volumeID)
	}
	// The stale cache entry MUST be gone. Either the fix explicitly
	// Deleted it, or the stub stager's error path left it absent — either
	// way, a subsequent NodePublishVolume would take the self-heal branch.
	if _, ok := ns.volumes.Load(volumeID); ok {
		t.Errorf("ns.volumes still contains stale entry for %s after SIGKILL recovery", volumeID)
	}
}

// TestNodePublishVolume_WarmCacheHealthyStaging_DoesNotReStage asserts that
// the v0.1.8 SIGKILL fix does NOT break the common fast path. When the
// cache is warm AND the staging path is healthy, NodePublishVolume must
// proceed directly to Publish without calling stageNewVolumeFunc or
// invalidating the cache.
func TestNodePublishVolume_WarmCacheHealthyStaging_DoesNotReStage(t *testing.T) {
	// Claim the staging path is healthy so the fast path is eligible.
	origIsHealthy := isStagingPathHealthy
	isStagingPathHealthy = func(stagingPath string) bool { return true }
	t.Cleanup(func() { isStagingPathHealthy = origIsHealthy })

	// stageNewVolumeFunc must NOT be called on the fast path. If the fix
	// accidentally fires on healthy mounts, stagerCalled catches it.
	origStager := stageNewVolumeFunc
	stagerCalled := false
	stageNewVolumeFunc = func(ns *NodeServer, ctx context.Context, volumeID, stagingTargetPath string, volContext map[string]string, readOnly bool) (*Volume, error) {
		stagerCalled = true
		return nil, errors.New("unexpected stager call on healthy fast path")
	}
	t.Cleanup(func() { stageNewVolumeFunc = origStager })

	stagingTargetPath := t.TempDir()
	targetPath := filepath.Join(t.TempDir(), "target")
	volumeID := "/buckets/pvc-test-healthy-hot-path"

	ns := &NodeServer{
		Driver:        &SeaweedFsDriver{},
		volumeMutexes: NewKeyMutex(),
	}
	ns.volumes.Store(volumeID, ns.rebuildVolumeFromStaging(volumeID, stagingTargetPath))

	// NodePublishVolume will proceed to Volume.Publish which calls
	// mountutil.Mount for a real bind mount; that fails in an unprivileged
	// test environment. We expect an error, but it must come from Publish
	// (i.e. AFTER the cache-hit fast path was correctly selected) — NOT
	// from stageNewVolumeFunc. The assertions below verify this.
	_, _ = ns.NodePublishVolume(context.Background(), publishRequestForTest(volumeID, stagingTargetPath, targetPath))

	if stagerCalled {
		t.Error("stageNewVolumeFunc was called on a warm-cache HEALTHY staging path — the v0.1.8 fix is too aggressive and broke the fast path")
	}
	if _, ok := ns.volumes.Load(volumeID); !ok {
		t.Error("cache entry was dropped on healthy fast path — the v0.1.8 fix is too aggressive and invalidated a still-live volume")
	}
}
