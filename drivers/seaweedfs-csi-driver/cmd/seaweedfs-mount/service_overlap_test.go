package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountmanager"
)

func TestRunMountServicePredecessorShutdownPreservesReplacementService(t *testing.T) {
	t.Parallel()

	socketPath := filepath.Join(t.TempDir(), "seaweedfs-mount.sock")

	oldCtx, oldCancel := context.WithCancel(context.Background())
	defer oldCancel()
	oldDone := make(chan error, 1)
	go func() {
		oldDone <- runMountService(oldCtx, socketPath, mountmanager.NewManager(mountmanager.Config{WeedBinary: mountmanager.DefaultWeedBinary}), newReadinessGate())
	}()

	waitForLiveMountService(t, socketPath)

	if err := os.Remove(socketPath); err != nil {
		t.Fatalf("remove old socket path for replacement bind: %v", err)
	}

	newCtx, newCancel := context.WithCancel(context.Background())
	defer newCancel()
	newDone := make(chan error, 1)
	go func() {
		newDone <- runMountService(newCtx, socketPath, mountmanager.NewManager(mountmanager.Config{WeedBinary: mountmanager.DefaultWeedBinary}), newReadinessGate())
	}()

	waitForLiveMountService(t, socketPath)

	oldCancel()
	select {
	case err := <-oldDone:
		if err != nil {
			t.Fatalf("old service exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for old service shutdown")
	}

	waitForLiveMountService(t, socketPath)

	newCancel()
	select {
	case err := <-newDone:
		if err != nil {
			t.Fatalf("new service exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for replacement service shutdown")
	}
}

func waitForLiveMountService(t *testing.T, socketPath string) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for {
		live, err := mountmanager.HasLiveService(context.Background(), "unix://"+socketPath)
		if err == nil && live {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("mount service at %s did not become live: live=%v err=%v", socketPath, live, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
