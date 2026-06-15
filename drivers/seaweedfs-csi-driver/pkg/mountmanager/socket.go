package mountmanager

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"path/filepath"
)

// DefaultSocketDir is the default directory for volume sockets.
const DefaultSocketDir = "/var/lib/seaweedfs-mount"

// LocalSocketPath returns the unix socket path used to communicate with the weed mount process.
// The baseDir parameter should be the directory where sockets are stored (e.g., derived from mountEndpoint).
// Uses SHA256 hash (first 16 hex chars = 64 bits) to minimize collision risk.
func LocalSocketPath(baseDir, volumeID string) string {
	if baseDir == "" {
		baseDir = DefaultSocketDir
	}
	h := sha256.Sum256([]byte(volumeID))
	hashStr := hex.EncodeToString(h[:8]) // 16 hex chars = 64 bits
	return filepath.Join(baseDir, fmt.Sprintf("seaweedfs-mount-%s.sock", hashStr))
}

// HandoffSocketPath returns a short-lived unixpacket socket path used to
// transfer a live FUSE device fd between overlapping mount-service pods.
func HandoffSocketPath(baseDir, nonce, volumeID string) string {
	if baseDir == "" {
		baseDir = DefaultSocketDir
	}
	h := sha256.Sum256([]byte(nonce + ":" + volumeID))
	hashStr := hex.EncodeToString(h[:8])
	return filepath.Join(baseDir, fmt.Sprintf("seaweedfs-handoff-%s.sock", hashStr))
}
