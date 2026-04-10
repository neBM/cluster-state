package driver

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

// newTestControllerServer returns a ControllerServer whose Driver is just
// enough to make CreateVolume work in-test. Any call that reaches the filer
// will panic unless we stub it — the tests below stub both the PVC lookup
// and the Mkdir path. cscap must be populated so ValidateControllerServiceRequest
// accepts RPC_CREATE_DELETE_VOLUME.
func newTestControllerServer(t *testing.T) *ControllerServer {
	t.Helper()
	d := &SeaweedFsDriver{
		RunController: true,
	}
	d.AddControllerServiceCapabilities([]csi.ControllerServiceCapability_RPC_Type{
		csi.ControllerServiceCapability_RPC_CREATE_DELETE_VOLUME,
	})
	return &ControllerServer{Driver: d}
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

	vctx := resp.Volume.VolumeContext
	if vctx["mountRootUid"] != "990" {
		t.Errorf("volumeContext mountRootUid: got %q, want %q", vctx["mountRootUid"], "990")
	}
	if vctx["mountRootGid"] != "997" {
		t.Errorf("volumeContext mountRootGid: got %q, want %q", vctx["mountRootGid"], "997")
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
