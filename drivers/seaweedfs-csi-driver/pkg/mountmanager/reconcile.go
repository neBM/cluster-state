package mountmanager

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/seaweedfs/seaweedfs/weed/glog"
)

// ReconcileStaleMounts scans /proc/self/mountinfo for fuse.seaweedfs mounts
// and lazy-unmounts every one it finds, along with any stale per-volume unix
// sockets in socketDir.
//
// At mount service startup there cannot legitimately be any live
// fuse.seaweedfs mounts on this node: this process is the only creator, and
// it has not yet accepted any /mount requests. Any entries in mountinfo are
// by definition orphans from a prior instance whose weed mount subprocesses
// have died (or are in the process of dying — the stat()-based staleness
// check races against subprocess teardown and leaks mounts, so we drop it).
//
// After this runs, kubelet's VolumeManager reconciler observes the consumer
// bind mounts missing and re-invokes NodePublishVolume, and the CSI plugin's
// existing self-healing path (see nodeserver.go NodePublishVolume /
// NodeStageVolume) re-establishes the mount via a fresh weed mount process.
//
// This is intended to be invoked at mount service startup, before the HTTP
// listener begins accepting requests, so that cleanup completes before any
// /mount call arrives.
func ReconcileStaleMounts(socketDir string) {
	mounts, err := findSeaweedFuseMounts()
	if err != nil {
		glog.Errorf("reconcile: failed to scan mountinfo: %v", err)
		return
	}

	if len(mounts) == 0 {
		glog.Infof("reconcile: no fuse.seaweedfs mounts found")
	} else {
		glog.Infof("reconcile: found %d fuse.seaweedfs mount(s), lazy-unmounting unconditionally", len(mounts))
	}

	for _, mp := range mounts {
		if err := lazyUnmount(mp); err != nil {
			glog.Errorf("reconcile: lazy-unmount %s: %v", mp, err)
			continue
		}
		glog.Infof("reconcile: lazy-unmounted %s", mp)
	}

	if socketDir == "" {
		socketDir = DefaultSocketDir
	}
	cleanupStaleVolumeSockets(socketDir)
}

// findSeaweedFuseMounts returns mount points of fuse.seaweedfs entries in
// /proc/self/mountinfo (deduped by path).
func findSeaweedFuseMounts() ([]string, error) {
	f, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var mounts []string
	seen := map[string]bool{}
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		mp, ok := parseMountInfoLineForSeaweedFuse(scanner.Text())
		if !ok {
			continue
		}
		if seen[mp] {
			continue
		}
		seen[mp] = true
		mounts = append(mounts, mp)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return mounts, nil
}

// parseMountInfoLineForSeaweedFuse returns (mountPoint, true) if the given
// /proc/self/mountinfo line describes a fuse.seaweedfs mount.
//
// Format (see proc(5)):
//
//	36 35 98:0 /mnt1 /mnt/parent rw,noatime master:1 - ext3 /dev/root rw,errors=continue
//	|  |  |    |     |          |                     |   |         |
//	0  1  2    3     4          5                     ^   ^         ^
//	                                             separator fstype   source
//
// Field 4 is the mount point. After the " - " separator the next token is the
// filesystem type.
func parseMountInfoLineForSeaweedFuse(line string) (string, bool) {
	sepIdx := strings.Index(line, " - ")
	if sepIdx < 0 {
		return "", false
	}

	head := line[:sepIdx]
	tail := line[sepIdx+3:]

	headFields := strings.Fields(head)
	if len(headFields) < 5 {
		return "", false
	}
	mountPoint := unescapeMountInfo(headFields[4])

	tailFields := strings.Fields(tail)
	if len(tailFields) < 1 {
		return "", false
	}
	fsType := tailFields[0]
	if fsType != "fuse.seaweedfs" {
		return "", false
	}
	return mountPoint, true
}

// unescapeMountInfo decodes the octal escapes used by the kernel in
// /proc/self/mountinfo for space (\040), tab (\011), newline (\012) and
// backslash (\134).
func unescapeMountInfo(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			switch s[i+1 : i+4] {
			case "040":
				b.WriteByte(' ')
				i += 3
				continue
			case "011":
				b.WriteByte('\t')
				i += 3
				continue
			case "012":
				b.WriteByte('\n')
				i += 3
				continue
			case "134":
				b.WriteByte('\\')
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// lazyUnmount detaches the mount point from the filesystem namespace without
// waiting for in-flight I/O to drain (MNT_DETACH). The detach propagates back
// to the host via bidirectional mount propagation on the daemonset's volume
// mounts.
func lazyUnmount(path string) error {
	return syscall.Unmount(path, syscall.MNT_DETACH)
}

// cleanupStaleVolumeSockets removes leftover per-volume unix sockets from
// previous mount service instances. The canonical socket dir is flat and
// contains "seaweedfs-mount-<hash>.sock" files created by LocalSocketPath.
// The service's own listener socket lives in the same directory and must be
// preserved; it is recreated by main().
func cleanupStaleVolumeSockets(socketDir string) {
	entries, err := os.ReadDir(socketDir)
	if err != nil {
		if !os.IsNotExist(err) {
			glog.Warningf("reconcile: read socket dir %s: %v", socketDir, err)
		}
		return
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, "seaweedfs-mount-") || !strings.HasSuffix(name, ".sock") {
			continue
		}
		if name == "seaweedfs-mount.sock" {
			continue
		}
		p := filepath.Join(socketDir, name)
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			glog.Warningf("reconcile: remove stale socket %s: %v", p, err)
			continue
		}
		glog.Infof("reconcile: removed stale volume socket %s", p)
	}
}
