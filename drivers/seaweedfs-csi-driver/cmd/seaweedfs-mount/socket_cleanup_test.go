package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRemoveSocketIfOwnedRemovesMatchingPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "socket")
	if err := os.WriteFile(path, []byte("first"), 0o600); err != nil {
		t.Fatalf("write original file: %v", err)
	}

	owned, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat original file: %v", err)
	}

	if err := removeSocketIfOwned(path, owned); err != nil {
		t.Fatalf("removeSocketIfOwned: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected path removal, stat err = %v", err)
	}
}

func TestRemoveSocketIfOwnedPreservesReplacementPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "socket")
	if err := os.WriteFile(path, []byte("first"), 0o600); err != nil {
		t.Fatalf("write original file: %v", err)
	}

	owned, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat original file: %v", err)
	}

	if err := os.Remove(path); err != nil {
		t.Fatalf("remove original file: %v", err)
	}
	if err := os.WriteFile(path, []byte("replacement"), 0o600); err != nil {
		t.Fatalf("write replacement file: %v", err)
	}

	if err := removeSocketIfOwned(path, owned); err != nil {
		t.Fatalf("removeSocketIfOwned: %v", err)
	}
	if data, err := os.ReadFile(path); err != nil {
		t.Fatalf("read replacement file: %v", err)
	} else if string(data) != "replacement" {
		t.Fatalf("replacement contents = %q, want %q", string(data), "replacement")
	}
}
