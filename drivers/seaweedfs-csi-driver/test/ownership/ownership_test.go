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
