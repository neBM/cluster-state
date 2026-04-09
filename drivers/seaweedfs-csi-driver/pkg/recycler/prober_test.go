package recycler

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseMountinfo_FiltersFuseSeaweedfs(t *testing.T) {
	sample := strings.Join([]string{
		// Standard root mount (filtered out)
		"21 28 0:20 / /sys rw,nosuid,nodev,noexec,relatime shared:7 - sysfs sysfs rw",
		// A fuse.seaweedfs consumer mount (kept)
		"123 45 0:100 / /var/lib/kubelet/pods/abc-1/volumes/kubernetes.io~csi/pvc-one/mount rw,relatime shared:99 - fuse.seaweedfs weed-mount rw",
		// A fuse.seaweedfs mount NOT under a consumer path (filtered out)
		"124 45 0:101 / /tmp/debug rw,relatime shared:100 - fuse.seaweedfs weed-mount rw",
		"",
	}, "\n")

	got := parseMountinfo(sample)
	if len(got) != 1 {
		t.Fatalf("want 1 consumer mount, got %d: %v", len(got), got)
	}
	if got[0] != "/var/lib/kubelet/pods/abc-1/volumes/kubernetes.io~csi/pvc-one/mount" {
		t.Errorf("unexpected mountpoint: %q", got[0])
	}
}

func TestStatProbe_TimesOut(t *testing.T) {
	// Create a fake stat binary that sleeps forever.
	dir := t.TempDir()
	script := filepath.Join(dir, "stat")
	body := "#!/bin/sh\nsleep 30\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	p := &Prober{StatPath: script, StatTimeout: 100 * time.Millisecond}
	err := p.probeOne(context.Background(), "/nonexistent")
	if err == nil {
		t.Fatal("want timeout error, got nil")
	}
}

func TestStatProbe_OK(t *testing.T) {
	statPath, err := exec.LookPath("stat")
	if err != nil {
		t.Skip("stat binary not in PATH")
	}
	p := &Prober{StatPath: statPath, StatTimeout: 2 * time.Second}
	if err := p.probeOne(context.Background(), "/"); err != nil {
		t.Fatalf("probeOne(/): %v", err)
	}
}
