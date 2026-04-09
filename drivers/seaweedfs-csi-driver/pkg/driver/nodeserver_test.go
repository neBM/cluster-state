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
