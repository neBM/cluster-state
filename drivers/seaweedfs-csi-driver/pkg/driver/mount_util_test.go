package driver

import (
	"testing"
)

// TestIsStagingPathHealthy_WrongFsType_ReturnsFalse verifies that when
// /proc/self/mountinfo lists a fstype other than fuse.seaweedfs at the
// staging path, isStagingPathHealthy treats it as stale and returns false.
//
// Motivation: the 2026-04-10 v0.1.6 cache-wipe incident left btrfs residue
// at csi globalmount paths after the FUSE layer died. The previous version
// of isStagingPathHealthy saw "is a mount point" + "ReadDir works" and
// reported healthy, so csi-node self-heal never cleaned it up. This check
// makes the self-heal path automatic for that class of failure.
func TestIsStagingPathHealthy_WrongFsType_ReturnsFalse(t *testing.T) {
	orig := lookupFilesystemType
	lookupFilesystemType = func(mountPoint string) (string, bool) {
		return "btrfs", true
	}
	t.Cleanup(func() { lookupFilesystemType = orig })

	// Path doesn't need to exist for this test — the fstype check runs
	// first and short-circuits before os.Stat.
	if isStagingPathHealthy("/var/lib/kubelet/plugins/kubernetes.io/csi/seaweedfs-csi-driver.seaweedfs.csi.k8s.io/0000-fake/globalmount") {
		t.Error("expected false when mountinfo reports non-fuse.seaweedfs fstype, got true")
	}
}

// TestIsStagingPathHealthy_UnknownPath_FallsThroughToOtherChecks verifies
// that when the staging path is not listed in mountinfo at all, the fstype
// check does not force a false — it leaves the decision to the existing
// stat/IsMountPoint/ReadDir checks.
func TestIsStagingPathHealthy_UnknownPath_FallsThroughToOtherChecks(t *testing.T) {
	orig := lookupFilesystemType
	lookupFilesystemType = func(mountPoint string) (string, bool) {
		return "", false
	}
	t.Cleanup(func() { lookupFilesystemType = orig })

	// A non-existent path will fail the os.Stat check below the fstype
	// check, so the function returns false. The test's real purpose is
	// to confirm the fstype branch does not panic / does not short-circuit
	// to true when mountinfo has no entry for the path.
	if isStagingPathHealthy("/nonexistent-path-for-test-never-created") {
		t.Error("expected false for a path that doesn't exist")
	}
}
