package recycler

import (
	"context"
	"errors"
	"fmt"
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

func TestProber_BaselinesStartupFailuresAcrossSweeps(t *testing.T) {
	root := t.TempDir()
	mountpoint := "/var/lib/kubelet/pods/abc-123/volumes/kubernetes.io~csi/pvc-one/mount"
	writeMountinfo(t, root, mountpoint)

	var triggered []string
	p := &Prober{
		ProcRoot: root,
		Trigger: func(ctx context.Context, mountpoint string) {
			triggered = append(triggered, mountpoint)
		},
		probeFunc: func(ctx context.Context, mountpoint string) error {
			return errors.New("stale mount")
		},
	}

	p.sweep(context.Background())
	p.sweep(context.Background())
	p.sweep(context.Background())

	if len(triggered) != 0 {
		t.Fatalf("startup-observed stale mounts should stay baselined across sweeps, got triggers %v", triggered)
	}
}

func TestProber_TriggersWhenMountRecoversThenFailsAgain(t *testing.T) {
	root := t.TempDir()
	mountpoint := "/var/lib/kubelet/pods/abc-123/volumes/kubernetes.io~csi/pvc-one/mount"
	writeMountinfo(t, root, mountpoint)

	fail := true
	var triggered []string
	p := &Prober{
		ProcRoot: root,
		Trigger: func(ctx context.Context, mountpoint string) {
			triggered = append(triggered, mountpoint)
		},
		probeFunc: func(ctx context.Context, mountpoint string) error {
			if fail {
				return errors.New("stale mount")
			}
			return nil
		},
	}

	p.sweep(context.Background()) // Baseline initial failure.
	fail = false
	p.sweep(context.Background()) // Recovery clears the baseline entry.
	fail = true
	p.sweep(context.Background()) // Fresh failure should trigger exactly once.
	p.sweep(context.Background()) // Repeated failure stays edge-triggered.

	if len(triggered) != 1 || triggered[0] != mountpoint {
		t.Fatalf("want one trigger after recovery then failure, got %v", triggered)
	}
}

func TestProber_TriggersNewFailureAfterHealthyBaseline(t *testing.T) {
	root := t.TempDir()
	mountpoint := "/var/lib/kubelet/pods/abc-123/volumes/kubernetes.io~csi/pvc-one/mount"
	writeMountinfo(t, root, mountpoint)

	fail := false
	var triggered []string
	p := &Prober{
		ProcRoot: root,
		Trigger: func(ctx context.Context, mountpoint string) {
			triggered = append(triggered, mountpoint)
		},
		probeFunc: func(ctx context.Context, mountpoint string) error {
			if fail {
				return errors.New("stale mount")
			}
			return nil
		},
	}

	p.sweep(context.Background()) // Healthy baseline.
	fail = true
	p.sweep(context.Background()) // New failure should trigger once.
	p.sweep(context.Background()) // Repeated failure should not re-trigger.

	if len(triggered) != 1 || triggered[0] != mountpoint {
		t.Fatalf("want one trigger for the first post-baseline failure, got %v", triggered)
	}
}

func writeMountinfo(t *testing.T, root string, mountpoints ...string) {
	t.Helper()

	mountinfoDir := filepath.Join(root, "self")
	if err := os.MkdirAll(mountinfoDir, 0o755); err != nil {
		t.Fatalf("mkdir mountinfo dir: %v", err)
	}

	lines := make([]string, 0, len(mountpoints))
	for i, mountpoint := range mountpoints {
		lines = append(lines, fmt.Sprintf(
			"%d 45 0:%d / %s rw,relatime shared:%d - fuse.seaweedfs weed-mount rw",
			123+i,
			100+i,
			mountpoint,
			99+i,
		))
	}

	if err := os.WriteFile(filepath.Join(mountinfoDir, "mountinfo"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatalf("write mountinfo: %v", err)
	}
}
