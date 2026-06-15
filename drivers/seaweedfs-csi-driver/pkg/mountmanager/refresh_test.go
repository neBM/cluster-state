package mountmanager

import (
	"context"
	"net"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountpb"
	"google.golang.org/grpc"
)

type fakeSeaweedMountServer struct {
	mountpb.UnimplementedSeaweedMountServer
	refreshCalls atomic.Int32
}

func (s *fakeSeaweedMountServer) RefreshVolumeLocations(context.Context, *mountpb.RefreshVolumeLocationsRequest) (*mountpb.RefreshVolumeLocationsResponse, error) {
	s.refreshCalls.Add(1)
	return &mountpb.RefreshVolumeLocationsResponse{}, nil
}

func newUnixMountGRPCServer(t *testing.T) (socketPath string, server *fakeSeaweedMountServer, closeFn func()) {
	t.Helper()

	dir := t.TempDir()
	socketPath = filepath.Join(dir, "mount-grpc.sock")
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}

	grpcServer := grpc.NewServer()
	server = &fakeSeaweedMountServer{}
	mountpb.RegisterSeaweedMountServer(grpcServer, server)
	go grpcServer.Serve(ln) //nolint:errcheck

	return socketPath, server, func() {
		grpcServer.Stop()
		_ = ln.Close()
	}
}

func TestRefreshVolumeLocations_FansOutToAllMounts(t *testing.T) {
	socketA, serverA, closeA := newUnixMountGRPCServer(t)
	defer closeA()
	socketB, serverB, closeB := newUnixMountGRPCServer(t)
	defer closeB()

	manager := NewManager(Config{})
	manager.mounts["vol-a"] = &mountEntry{volumeID: "vol-a", localSocket: socketA}
	manager.mounts["vol-b"] = &mountEntry{volumeID: "vol-b", localSocket: socketB}

	resp, err := manager.RefreshVolumeLocations(&RefreshVolumeLocationsRequest{})
	if err != nil {
		t.Fatalf("RefreshVolumeLocations: %v", err)
	}
	if len(resp.Refreshed) != 2 {
		t.Fatalf("refreshed = %v, want 2 entries", resp.Refreshed)
	}
	if len(resp.Failed) != 0 {
		t.Fatalf("failed = %v, want none", resp.Failed)
	}
	if got := serverA.refreshCalls.Load(); got != 1 {
		t.Fatalf("server A refresh calls = %d, want 1", got)
	}
	if got := serverB.refreshCalls.Load(); got != 1 {
		t.Fatalf("server B refresh calls = %d, want 1", got)
	}
}

func TestRefreshVolumeLocations_ReportsPerMountFailures(t *testing.T) {
	socketA, serverA, closeA := newUnixMountGRPCServer(t)
	defer closeA()

	manager := NewManager(Config{})
	manager.mounts["vol-a"] = &mountEntry{volumeID: "vol-a", localSocket: socketA}
	manager.mounts["vol-b"] = &mountEntry{volumeID: "vol-b", localSocket: filepath.Join(t.TempDir(), "missing.sock")}

	resp, err := manager.RefreshVolumeLocations(&RefreshVolumeLocationsRequest{})
	if err != nil {
		t.Fatalf("RefreshVolumeLocations: %v", err)
	}
	if len(resp.Refreshed) != 1 || resp.Refreshed[0] != "vol-a" {
		t.Fatalf("refreshed = %v, want [vol-a]", resp.Refreshed)
	}
	if len(resp.Failed) != 1 {
		t.Fatalf("failed = %v, want 1 entry", resp.Failed)
	}
	if resp.Failed[0].VolumeID != "vol-b" {
		t.Fatalf("failed volumeID = %q, want %q", resp.Failed[0].VolumeID, "vol-b")
	}
	if resp.Failed[0].Error == "" {
		t.Fatal("expected failed entry to include an error message")
	}
	if got := serverA.refreshCalls.Load(); got != 1 {
		t.Fatalf("server A refresh calls = %d, want 1", got)
	}
}
