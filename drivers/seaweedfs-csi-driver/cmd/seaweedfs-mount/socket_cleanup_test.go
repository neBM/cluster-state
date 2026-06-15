package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestListenOwnedUnixSocketCloseLeavesPathForStartupCleanup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "socket")
	listener, err := listenOwnedUnixSocket(path)
	if err != nil {
		t.Fatalf("listen socket: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close listener: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected closed listener path to remain for startup cleanup: %v", err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatalf("cleanup socket path: %v", err)
	}
}

func TestListenOwnedUnixSocketPredecessorClosePreservesReplacementPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "socket")

	oldListener, err := listenOwnedUnixSocket(path)
	if err != nil {
		t.Fatalf("listen old socket: %v", err)
	}
	oldClosed := false
	t.Cleanup(func() {
		if !oldClosed {
			_ = oldListener.Close()
		}
	})

	if err := os.Remove(path); err != nil {
		t.Fatalf("remove old socket path for successor bind: %v", err)
	}

	newListener, err := listenOwnedUnixSocket(path)
	if err != nil {
		t.Fatalf("listen replacement socket: %v", err)
	}
	t.Cleanup(func() {
		_ = newListener.Close()
		_ = os.Remove(path)
	})

	if err := oldListener.Close(); err != nil {
		t.Fatalf("close old listener: %v", err)
	}
	oldClosed = true

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("replacement socket path removed by predecessor close: %v", err)
	}
}
