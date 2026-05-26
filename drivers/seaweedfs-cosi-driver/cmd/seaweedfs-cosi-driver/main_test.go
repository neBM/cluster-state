/*
Copyright 2026 SeaweedFS contributors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoveStaleUnixSocketRemovesClosedSocket(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "cosi.sock")

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("create unix socket: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close unix socket: %v", err)
	}

	if err := removeStaleUnixSocket("unix://" + socketPath); err != nil {
		t.Fatalf("remove stale socket: %v", err)
	}

	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("socket path still exists after cleanup: %v", err)
	}
}

func TestRemoveStaleUnixSocketKeepsActiveSocket(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "cosi.sock")

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("create unix socket: %v", err)
	}
	defer listener.Close()

	err = removeStaleUnixSocket("unix://" + socketPath)
	if err == nil {
		t.Fatal("expected active socket cleanup to fail")
	}
	if !strings.Contains(err.Error(), "active COSI endpoint socket") {
		t.Fatalf("expected active socket error, got %v", err)
	}

	info, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("active socket path was removed: %v", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("expected socket path, got mode %s", info.Mode())
	}
}

func TestRemoveStaleUnixSocketRejectsNonSocket(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "cosi.sock")
	if err := os.WriteFile(socketPath, []byte("not a socket"), 0600); err != nil {
		t.Fatalf("write non-socket endpoint path: %v", err)
	}

	err := removeStaleUnixSocket("unix://" + socketPath)
	if err == nil {
		t.Fatal("expected non-socket cleanup to fail")
	}
	if !strings.Contains(err.Error(), "non-socket COSI endpoint") {
		t.Fatalf("expected non-socket error, got %v", err)
	}
}

func TestRemoveStaleUnixSocketIgnoresMissingAndNonUnixEndpoints(t *testing.T) {
	missingSocket := filepath.Join(t.TempDir(), "missing.sock")
	if err := removeStaleUnixSocket("unix://" + missingSocket); err != nil {
		t.Fatalf("missing socket should be ignored: %v", err)
	}

	if err := removeStaleUnixSocket("tcp://127.0.0.1:9999"); err != nil {
		t.Fatalf("non-unix endpoint should be ignored: %v", err)
	}
}
