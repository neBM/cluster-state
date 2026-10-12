package mountmanager

import (
	"os"
	"testing"
)

// socketTempDir avoids t.TempDir's test-name prefix exceeding Unix socket
// path limits. The caller must use a short absolute TMPDIR as well.
func socketTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "sock-")
	if err != nil {
		t.Fatalf("create socket directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(dir); err != nil {
			t.Errorf("remove socket directory: %v", err)
		}
	})
	return dir
}
