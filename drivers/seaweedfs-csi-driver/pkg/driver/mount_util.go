package driver

import (
	"errors"
	"os"
	"time"

	"github.com/seaweedfs/seaweedfs/weed/glog"
	"k8s.io/mount-utils"
)

var mountutil = mount.New("")

// lookupFilesystemType returns the filesystem type listed in the host mount
// table for the given mount point. Returns ("", false) if the path is not a
// mount point according to the mount table, or if the lookup itself fails.
// Overridable for tests.
var lookupFilesystemType = defaultLookupFilesystemType

func defaultLookupFilesystemType(mountPoint string) (string, bool) {
	mounts, err := mountutil.List()
	if err != nil {
		glog.V(4).Infof("mount list failed while looking up fstype for %s: %v", mountPoint, err)
		return "", false
	}
	for _, mp := range mounts {
		if mp.Path == mountPoint {
			return mp.Type, true
		}
	}
	return "", false
}

// isStagingPathHealthy checks if the staging path has a healthy FUSE mount.
// It returns true if the path is mounted and accessible, false otherwise.
// Overridable for tests (so NodePublishVolume's warm-cache unhealthy-staging
// branch can be exercised without a real FUSE mount).
var isStagingPathHealthy = defaultIsStagingPathHealthy

func defaultIsStagingPathHealthy(stagingPath string) bool {
	// Early-out: if the host mount table lists a filesystem at this path
	// whose type is not fuse.seaweedfs, it is residue (e.g. leftover btrfs
	// or tmpfs from an earlier incident recovery) that must be cleaned up
	// before self-heal re-stages via the mount service. This makes the
	// class of failure that required manual intervention on 2026-04-10
	// (v0.1.6 cache-wipe recovery) self-healing without human hands.
	if fsType, ok := lookupFilesystemType(stagingPath); ok && fsType != "fuse.seaweedfs" {
		glog.Warningf("staging path %s has fstype %q, expected fuse.seaweedfs — treating as stale", stagingPath, fsType)
		return false
	}

	// Check if path exists
	info, err := os.Stat(stagingPath)
	if err != nil {
		if os.IsNotExist(err) {
			glog.V(4).Infof("staging path %s does not exist", stagingPath)
			return false
		}
		// "Transport endpoint is not connected" or similar FUSE errors
		if mount.IsCorruptedMnt(err) {
			glog.Warningf("staging path %s has corrupted mount: %v", stagingPath, err)
			return false
		}
		glog.V(4).Infof("staging path %s stat error: %v", stagingPath, err)
		return false
	}

	// Check if it's a directory
	if !info.IsDir() {
		glog.Warningf("staging path %s is not a directory", stagingPath)
		return false
	}

	// Check if it's a mount point
	isMnt, err := mountutil.IsMountPoint(stagingPath)
	if err != nil {
		if mount.IsCorruptedMnt(err) {
			glog.Warningf("staging path %s has corrupted mount point: %v", stagingPath, err)
			return false
		}
		glog.V(4).Infof("staging path %s mount point check error: %v", stagingPath, err)
		return false
	}

	if !isMnt {
		glog.V(4).Infof("staging path %s is not a mount point", stagingPath)
		return false
	}

	// Try to read the directory to verify FUSE is responsive
	_, err = os.ReadDir(stagingPath)
	if err != nil {
		glog.Warningf("staging path %s is not readable (FUSE may be dead): %v", stagingPath, err)
		return false
	}

	glog.V(4).Infof("staging path %s is healthy", stagingPath)
	return true
}

// cleanupStaleStagingPath cleans up a stale or corrupted staging mount point.
// It attempts to unmount and remove the directory.
func cleanupStaleStagingPath(stagingPath string) error {
	glog.Infof("cleaning up stale staging path %s", stagingPath)

	// Try to unmount first (handles corrupted mounts)
	if err := mountutil.Unmount(stagingPath); err != nil {
		glog.V(4).Infof("unmount staging path %s (may already be unmounted): %v", stagingPath, err)
	}

	// Check if directory still exists and remove it
	// Use RemoveAll to handle cases where directory is not empty after imperfect unmount
	if _, err := os.Stat(stagingPath); err == nil {
		if err := os.RemoveAll(stagingPath); err != nil {
			glog.Warningf("failed to remove staging path %s: %v", stagingPath, err)
			return err
		}
	} else if !os.IsNotExist(err) {
		// If stat fails with a different error (like corrupted mount), try force cleanup
		if mount.IsCorruptedMnt(err) {
			// Force unmount for corrupted mounts
			if cleanupErr := mount.CleanupMountPoint(stagingPath, mountutil, true); cleanupErr != nil {
				glog.Warningf("failed to cleanup corrupted mount point %s: %v", stagingPath, cleanupErr)
				return cleanupErr
			}
		} else {
			// stat failed with an unexpected error, return it
			glog.Warningf("stat on staging path %s failed during cleanup: %v", stagingPath, err)
			return err
		}
	}

	glog.Infof("successfully cleaned up staging path %s", stagingPath)
	return nil
}

func waitForMount(path string, timeout time.Duration) error {
	var elapsed time.Duration
	var interval = 10 * time.Millisecond
	for {
		notMount, err := mountutil.IsLikelyNotMountPoint(path)
		if err != nil {
			return err
		}
		if !notMount {
			return nil
		}
		time.Sleep(interval)
		elapsed = elapsed + interval
		if elapsed >= timeout {
			return errors.New("timeout waiting for mount")
		}
	}
}
