package mountmanager

import (
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// TestMount_StaleDeadEntry_FallsThroughToRespawn covers Bug A (v0.1.7):
// when m.mounts has a cached entry whose weed mount process has already
// exited, a new Mount RPC must NOT return the stale localSocket. It must
// detect the dead process via Process.Signal(0), detach the stale entry
// from m.mounts, and fall through to spawn a fresh weed mount process.
//
// Before the fix: Mount returned (stale socket, nil) and never respawned.
// After the fix: Mount falls through to startMount. In this test we use a
// deliberately missing weedBinary so the fresh spawn fails fast — the
// non-nil error is our proof that the fast-path did not short-circuit.
func TestMount_StaleDeadEntry_FallsThroughToRespawn(t *testing.T) {
	m := NewManager(Config{WeedBinary: "/nonexistent-weed-binary-for-test"})

	dead := exec.Command("/bin/true")
	if err := dead.Start(); err != nil {
		t.Fatalf("spawning /bin/true: %v", err)
	}
	if err := dead.Wait(); err != nil {
		t.Fatalf("waiting /bin/true: %v", err)
	}
	if err := dead.Process.Signal(syscall.Signal(0)); err == nil {
		t.Fatal("precondition: expected Signal(0) on an already-waited process to error, got nil")
	}

	targetDir := t.TempDir()
	volumeID := "test-vol"
	staleSocket := "/tmp/stale-test.sock"

	m.mu.Lock()
	m.mounts[volumeID] = &mountEntry{
		volumeID:    volumeID,
		targetPath:  targetDir,
		cacheDir:    t.TempDir(),
		localSocket: staleSocket,
		process: &weedMountProcess{
			cmd:    dead,
			target: targetDir,
			done:   make(chan struct{}),
		},
	}
	m.mu.Unlock()

	_, err := m.Mount(&MountRequest{
		VolumeID:    volumeID,
		TargetPath:  targetDir,
		CacheDir:    t.TempDir(),
		LocalSocket: "/tmp/fresh-test.sock",
		MountArgs:   []string{"mount", "-filer=localhost:8888"},
	})
	if err == nil {
		t.Fatal("Bug A not fixed: Mount short-circuited on stale dead entry instead of attempting a fresh spawn")
	}

	m.mu.Lock()
	entry := m.mounts[volumeID]
	m.mu.Unlock()
	if entry != nil {
		t.Errorf("stale entry still in m.mounts after failed respawn; fast-path did not detach it")
	}
}

// TestMount_LiveEntry_FastPathStillWorks is a regression check: the
// "already mounted" fast-path must continue to return the cached socket
// when the underlying weed mount process is still running. This protects
// against overshooting the Bug A fix.
func TestMount_LiveEntry_FastPathStillWorks(t *testing.T) {
	m := NewManager(Config{})

	live := exec.Command("/bin/sleep", "30")
	if err := live.Start(); err != nil {
		t.Fatalf("spawning /bin/sleep: %v", err)
	}
	t.Cleanup(func() {
		_ = live.Process.Kill()
		_, _ = live.Process.Wait()
	})

	targetDir := t.TempDir()
	volumeID := "test-vol"
	liveSocket := "/tmp/live-test.sock"

	m.mu.Lock()
	m.mounts[volumeID] = &mountEntry{
		volumeID:    volumeID,
		targetPath:  targetDir,
		cacheDir:    t.TempDir(),
		localSocket: liveSocket,
		process: &weedMountProcess{
			cmd:    live,
			target: targetDir,
			done:   make(chan struct{}),
		},
	}
	m.mu.Unlock()

	resp, err := m.Mount(&MountRequest{
		VolumeID:    volumeID,
		TargetPath:  targetDir,
		CacheDir:    t.TempDir(),
		LocalSocket: "/tmp/fresh-test.sock",
		MountArgs:   []string{"mount", "-filer=localhost:8888"},
	})
	if err != nil {
		t.Fatalf("fast-path failed unexpectedly: %v", err)
	}
	if resp.LocalSocket != liveSocket {
		t.Errorf("fast-path returned wrong socket: got %q, want %q", resp.LocalSocket, liveSocket)
	}

	m.mu.Lock()
	entry := m.mounts[volumeID]
	m.mu.Unlock()
	if entry == nil {
		t.Error("live entry was detached even though process is alive")
	}
}

// TestWeedMountProcessWait_DetachesFromManagerOnExit covers Bug B (v0.1.7):
// when a weed mount process exits unexpectedly, wait()'s cleanup must
// remove the entry from m.mounts so that future Mount RPCs respawn a
// fresh process instead of finding a cached-but-dead entry.
//
// Before the fix: m.mounts still contained the stale entry after wait()
// returned. After the fix: wait() invokes an onExit hook set by
// startMount which calls detachMount.
func TestWeedMountProcessWait_DetachesFromManagerOnExit(t *testing.T) {
	m := NewManager(Config{})
	volumeID := "test-vol"

	cmd := exec.Command("/bin/sleep", "0.05")
	if err := cmd.Start(); err != nil {
		t.Fatalf("spawning sleep: %v", err)
	}

	p := &weedMountProcess{
		cmd:    cmd,
		target: t.TempDir(),
		done:   make(chan struct{}),
		onExit: func() { m.detachMount(volumeID) },
	}

	m.mu.Lock()
	m.mounts[volumeID] = &mountEntry{
		volumeID: volumeID,
		process:  p,
	}
	m.mu.Unlock()

	go p.wait()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		m.mu.Lock()
		entry := m.mounts[volumeID]
		m.mu.Unlock()
		if entry == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("Bug B not fixed: wait() did not remove entry from m.mounts within 3s")
}
