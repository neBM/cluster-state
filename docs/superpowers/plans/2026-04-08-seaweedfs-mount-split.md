# SeaweedFS Mount Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the FUSE daemon (`seaweedfs-mount`) out of the `seaweedfs-csi-node` DaemonSet into its own DaemonSet, so CSI driver restarts (upgrades, crashloops, registrar updates) no longer kill FUSE sessions and orphan consumer mounts.

**Architecture:** Today, `seaweedfs-csi-node` is a single DaemonSet with 4 containers where `seaweedfs-mount` (owner of all `weed mount` FUSE subprocesses) shares a pod lifecycle with `csi-seaweedfs`, `node-driver-registrar`, and `liveness-probe`. This plan separates `seaweedfs-mount` into its own DaemonSet (`seaweedfs-mount`) with `OnDelete` update strategy (operator-controlled restarts). The two DaemonSets communicate via a hostPath socket at `/var/lib/seaweedfs-mount/seaweedfs-mount.sock` (previously an emptyDir, which only worked inside a single pod). The cache dir at `/var/cache/seaweedfs` also becomes hostPath so both pods can see per-volume cache/sockets for the existing `CleanupVolumeResources` path. While doing the image rebuild, we also fix the reconcile.go race (bug 1 from the 2026-04-08 cold-restart test) by dropping the `isStaleFuseMount` check — at `seaweedfs-mount` startup no live fuse.seaweedfs mounts should exist on this node (this process is the only creator), so unmount unconditionally.

**Tech Stack:** Go (seaweedfs-csi-driver fork), Docker buildx (multiarch amd64+arm64), containerd (`k3s ctr`), Terraform (kubernetes provider), k3s 1.29-class, Fedora 43 nodes.

---

## Background context (read before starting)

**Failure mode this fixes** (see memory `project_seaweedfs_reconcile_propagation_2026_04_08.md`):
- When `seaweedfs-csi-node` pod restarts, `seaweedfs-mount` container restarts with it, all `weed mount` subprocesses die, all FUSE sessions become ENOTCONN. Consumer pods on the node see stale bind mounts. Kubelet's VolumeManager only checks path existence (not health), so NodePublishVolume is never re-invoked. Consumers stay broken until manually restarted.
- The prior attempt (HostToContainer propagation on consumer volumeMounts + reconcile-on-startup in seaweedfs-mount) does **not** close the recovery loop: kernel `propagate_umount()` skips slaves whose mount is in use (open file descriptors), so busy consumer pods never see the unmount propagated.

**What this split achieves:**
- csi-node restarts (driver upgrades, registrar updates, crashloops, liveness probe failures) no longer affect `seaweedfs-mount` → FUSE sessions survive → consumers unaffected. ✓
- `seaweedfs-mount` restarts become a deliberate operator action (OnDelete update strategy) — no automatic rolling. When one IS triggered, consumer recycling is a known, planned operation.

**What this does NOT achieve:**
- A `seaweedfs-mount` restart (voluntary or crash) still kills FUSE and requires consumer recycling. This plan does not solve session recovery. It *reduces the frequency* of the failure and *gates* it behind operator action.

**First deploy is disruptive**: the current `seaweedfs-csi-node` pod has live `seaweedfs-mount` in it. Removing that container via terraform apply kills all FUSE sessions on every node simultaneously. Plan includes a consumer-pod cycling step after apply.

## Host IPs and SSH gotchas
- hestia=192.168.1.5 (amd64), heracles=192.168.1.6 (arm64), nyx=192.168.1.7 (arm64)
- SSH: use `/usr/bin/ssh ben@<ip>` (kitty's ssh kitten blocks non-interactive). Needs `sudo` on remote for `/proc/self/mountinfo`, `ctr`, `journalctl`.
- Remote shell aliases `ls` to `exa`; use `/bin/ls` explicitly.
- Registry `registry.brmartin.co.uk/ben` is backed by the very CSI we're editing — **do not push**. Sideload via `k3s ctr -n k8s.io images import <tar>`.
- Buildx builder: `multiarch` (amd64+arm64).

## Repos
- CSI driver: `~/Documents/Personal/projects/seaweedfs-csi-driver`, branch `feat/volume-mount-group`, baseline commit `fd82778`. Dev name: `seaweedfs-csi-driver`.
- IaC: `~/Documents/Personal/projects/iac/cluster-state`, branch `main`.

---

## File Structure

**Modify:**
- `~/Documents/Personal/projects/seaweedfs-csi-driver/pkg/mountmanager/reconcile.go` — drop `isStaleFuseMount` check, unmount unconditionally.
- `~/Documents/Personal/projects/iac/cluster-state/modules-k8s/seaweedfs/csi.tf` — restructure DaemonSets (remove mount container + init container from csi-node; add new seaweedfs-mount DaemonSet; change mount-socket/cache from emptyDir to hostPath).
- `~/Documents/Personal/projects/iac/cluster-state/modules-k8s/seaweedfs/variables.tf` — bump `csi_driver_image_tag` and `csi_mount_image_tag` to `v1.4.8-split`.

**Create:**
- `~/Documents/Personal/projects/seaweedfs-csi-driver/pkg/mountmanager/reconcile_test.go` (only if not present; otherwise update) — verify reconcile unmounts all fuse.seaweedfs entries unconditionally.
- `/var/cache/seaweedfs` and `/var/lib/seaweedfs-mount` hostPath dirs on each node (terraform `DirectoryOrCreate` handles this at first apply).

**Untouched (verify don't break):**
- `~/Documents/Personal/projects/iac/cluster-state/modules-k8s/seaweedfs/csi-rbac.tf` — csi-node service account is shared by both DaemonSets; same RBAC.
- `~/Documents/Personal/projects/iac/cluster-state/modules-k8s/seaweedfs/variables.tf` image tags for provisioner/attacher/resizer/registrar/livenessprobe — unchanged.
- The 12 consumer modules that previously got HostToContainer propagation — **leave as-is**. The propagation is now functionally inert but harmless, and touching them would create rollout churn. A future cleanup can remove them if desired.

---

## Task 1: Fix reconcile.go race (bug 1)

**Files:**
- Modify: `~/Documents/Personal/projects/seaweedfs-csi-driver/pkg/mountmanager/reconcile.go:31-94`

**Context:** The current `ReconcileStaleMounts` filters via `isStaleFuseMount`, which uses `os.Stat(mp)` to detect ENOTCONN. When the previous `seaweedfs-mount` container died, its child `weed mount` processes die asynchronously — at reconcile time, some FUSE sessions still stat-succeed. Those get skipped and remain orphaned on the host. Fix: at `seaweedfs-mount` startup there cannot legitimately be any live `fuse.seaweedfs` mounts on this node (this process is the sole creator; it just started). Unmount unconditionally. This also simplifies the code.

- [ ] **Step 1.1: Rewrite reconcile.go to unmount all fuse.seaweedfs mounts unconditionally**

Replace the body of `ReconcileStaleMounts`, `findStaleSeaweedFuseMounts`, and remove `isStaleFuseMount`. Full new file content:

```go
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
```

Key deletions vs the old file: removed `errors`, `syscall.ENOTCONN`-related imports' use, removed `isStaleFuseMount()`, renamed `findStaleSeaweedFuseMounts` → `findSeaweedFuseMounts`, and renamed the local `stale` slice to `mounts`. Keep `k8s.io/mount-utils` import ONLY IF something else in the file uses it — in the new version nothing does, so it is dropped (if goimports complains, remove it).

- [ ] **Step 1.2: Build the driver binary locally to smoke-test the code compiles**

```bash
cd ~/Documents/Personal/projects/seaweedfs-csi-driver
go build ./...
```
Expected: exit 0, no output. If it errors about unused imports, drop `errors` and `k8s.io/mount-utils` from reconcile.go.

- [ ] **Step 1.3: Run existing tests**

```bash
cd ~/Documents/Personal/projects/seaweedfs-csi-driver
go test ./pkg/mountmanager/...
```
Expected: PASS. If a test named `TestIsStaleFuseMount` exists and fails, delete that test (the function no longer exists). If a test calls `findStaleSeaweedFuseMounts`, rename the call to `findSeaweedFuseMounts` in the test.

- [ ] **Step 1.4: Commit**

```bash
cd ~/Documents/Personal/projects/seaweedfs-csi-driver
git add pkg/mountmanager/reconcile.go
# include reconcile_test.go if you had to touch it
git commit -m "mountmanager: reconcile unconditionally unmounts at startup

The stat()-based staleness check races against weed mount subprocess
teardown: at the moment the new mount service runs reconcile, some
FUSE sessions from the prior instance still stat-succeed, get filtered
out, and leak as stale mounts on the host.

At startup the mount service is the sole creator of fuse.seaweedfs
mounts on this node and has not yet accepted any /mount requests. Any
entries in mountinfo are by definition orphans from a prior instance.
Unmount them all.
"
```

---

## Task 2: Build and sideload v1.4.8-split images

**Files:** none (produces tar artifacts)

**Context:** Registry `registry.brmartin.co.uk/ben` is backed by the CSI we're replacing; pushing is impossible. Build multiarch tars locally, `scp` to each node, `k3s ctr images import`.

- [ ] **Step 2.1: Build multiarch tars via buildx**

```bash
cd ~/Documents/Personal/projects/seaweedfs-csi-driver
# Ensure the multiarch builder is running
docker buildx use multiarch
docker buildx inspect --bootstrap

mkdir -p _output/deploy

# CSI driver image
docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile \
  -t registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v1.4.8-split \
  -o type=docker,dest=_output/deploy/csi-driver-amd64.tar \
  .

docker buildx build \
  --platform linux/arm64 \
  -f Dockerfile \
  -t registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v1.4.8-split \
  -o type=docker,dest=_output/deploy/csi-driver-arm64.tar \
  .

# Mount helper image
docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile.mount \
  -t registry.brmartin.co.uk/ben/seaweedfs-mount:v1.4.8-split \
  -o type=docker,dest=_output/deploy/mount-amd64.tar \
  .

docker buildx build \
  --platform linux/arm64 \
  -f Dockerfile.mount \
  -t registry.brmartin.co.uk/ben/seaweedfs-mount:v1.4.8-split \
  -o type=docker,dest=_output/deploy/mount-arm64.tar \
  .
```
Expected: 4 tar files in `_output/deploy/`. If the Dockerfile names differ (`Dockerfile.csi` / `Dockerfile.mount`), check `~/Documents/Personal/projects/seaweedfs-csi-driver/` — the prior v1.4.7-reconcile build used the same Dockerfiles, so filenames are identical.

- [ ] **Step 2.2: Sideload to hestia (amd64)**

```bash
scp ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/csi-driver-amd64.tar ben@192.168.1.5:/tmp/
scp ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/mount-amd64.tar ben@192.168.1.5:/tmp/
/usr/bin/ssh ben@192.168.1.5 'sudo k3s ctr -n k8s.io images import /tmp/csi-driver-amd64.tar && sudo k3s ctr -n k8s.io images import /tmp/mount-amd64.tar && rm /tmp/csi-driver-amd64.tar /tmp/mount-amd64.tar'
```
Expected: output like `unpacking ... registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v1.4.8-split ... done` for both.

- [ ] **Step 2.3: Sideload to heracles (arm64)**

```bash
scp ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/csi-driver-arm64.tar ben@192.168.1.6:/tmp/
scp ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/mount-arm64.tar ben@192.168.1.6:/tmp/
/usr/bin/ssh ben@192.168.1.6 'sudo k3s ctr -n k8s.io images import /tmp/csi-driver-arm64.tar && sudo k3s ctr -n k8s.io images import /tmp/mount-arm64.tar && rm /tmp/csi-driver-arm64.tar /tmp/mount-arm64.tar'
```
Expected: same import messages as hestia.

- [ ] **Step 2.4: Sideload to nyx (arm64)**

```bash
scp ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/csi-driver-arm64.tar ben@192.168.1.7:/tmp/
scp ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/mount-arm64.tar ben@192.168.1.7:/tmp/
/usr/bin/ssh ben@192.168.1.7 'sudo k3s ctr -n k8s.io images import /tmp/csi-driver-arm64.tar && sudo k3s ctr -n k8s.io images import /tmp/mount-arm64.tar && rm /tmp/csi-driver-arm64.tar /tmp/mount-arm64.tar'
```
Expected: same import messages.

- [ ] **Step 2.5: Verify images visible on all nodes**

```bash
for ip in 192.168.1.5 192.168.1.6 192.168.1.7; do
  echo "=== $ip ==="
  /usr/bin/ssh ben@$ip 'sudo k3s ctr -n k8s.io images ls | /bin/grep v1.4.8-split'
done
```
Expected: 2 lines per node (driver + mount).

---

## Task 3: Bump image tags in variables.tf

**Files:**
- Modify: `~/Documents/Personal/projects/iac/cluster-state/modules-k8s/seaweedfs/variables.tf`

- [ ] **Step 3.1: Change both tags from v1.4.7-reconcile to v1.4.8-split**

Use Edit to change the `default` value of `csi_driver_image_tag` and `csi_mount_image_tag` variables. If the variables don't exist in variables.tf but are set in the calling module, grep for them:

```bash
cd ~/Documents/Personal/projects/iac/cluster-state
grep -rn 'csi_driver_image_tag\|csi_mount_image_tag' modules-k8s/seaweedfs/ kubernetes.tf
```

Edit whichever file holds the default, replacing `v1.4.7-reconcile` → `v1.4.8-split` for both tags.

- [ ] **Step 3.2: Verify**

```bash
cd ~/Documents/Personal/projects/iac/cluster-state
grep -rn 'v1\.4\.[78]' modules-k8s/seaweedfs/ kubernetes.tf
```
Expected: all occurrences show `v1.4.8-split`, none show `v1.4.7-reconcile`.

---

## Task 4: Restructure csi.tf — remove mount from csi-node, add new DaemonSet

**Files:**
- Modify: `~/Documents/Personal/projects/iac/cluster-state/modules-k8s/seaweedfs/csi.tf`

**Context:** Four separate changes in one file:
1. Delete the `cleanup-stale-mounts` init container (its job is now done by reconcile.go in seaweedfs-mount).
2. Delete the `seaweedfs-mount` container from the `csi_node` DaemonSet.
3. Change `mount-socket` volume from `empty_dir {}` to `host_path { path = "/var/lib/seaweedfs-mount", type = "DirectoryOrCreate" }` (so the new DaemonSet can share the socket).
4. Change `cache` volume from `empty_dir {}` to `host_path { path = "/var/cache/seaweedfs", type = "DirectoryOrCreate" }` (so both pods see the same per-volume cache/socket dirs used by `CleanupVolumeResources`).
5. Add a NEW resource `kubernetes_daemon_set_v1.seaweedfs_mount` with the seaweedfs-mount container, OnDelete strategy, and the shared hostPath volumes.

- [ ] **Step 4.1: Delete cleanup-stale-mounts init_container block**

In `csi.tf`, delete the entire `init_container { name = "cleanup-stale-mounts" ... }` block inside `kubernetes_daemon_set_v1.csi_node` (lines ~238-264 in the pre-change file). There is no replacement.

- [ ] **Step 4.2: Delete seaweedfs-mount container block from csi-node**

In `csi.tf`, delete the entire `container { name = "seaweedfs-mount" ... }` block inside `kubernetes_daemon_set_v1.csi_node` (the final container in the spec, lines ~453-504 pre-change). Leave the other three containers (csi-seaweedfs, node-driver-registrar, liveness-probe) intact.

- [ ] **Step 4.3: Change mount-socket volume to hostPath**

Replace:
```hcl
volume {
  name = "mount-socket"
  empty_dir {}
}
```
With:
```hcl
volume {
  name = "mount-socket"
  host_path {
    path = "/var/lib/seaweedfs-mount"
    type = "DirectoryOrCreate"
  }
}
```

- [ ] **Step 4.4: Change cache volume to hostPath**

Replace:
```hcl
volume {
  name = "cache"
  empty_dir {}
}
```
With:
```hcl
volume {
  name = "cache"
  host_path {
    path = "/var/cache/seaweedfs"
    type = "DirectoryOrCreate"
  }
}
```

- [ ] **Step 4.5: Append the new seaweedfs_mount DaemonSet resource**

Append this resource to the end of `csi.tf`. This is a new resource, not a replacement.

```hcl
# -----------------------------------------------------------------------------
# SeaweedFS Mount — DaemonSet (FUSE daemon host, independent lifecycle)
#
# Split from seaweedfs-csi-node so that CSI driver restarts do not kill FUSE
# sessions. Update strategy is OnDelete: operator-controlled restarts only,
# because restarting this DaemonSet kills all weed mount subprocesses and
# requires cycling every consumer pod on each affected node.
# -----------------------------------------------------------------------------

resource "kubernetes_daemon_set_v1" "seaweedfs_mount" {
  metadata {
    name      = "seaweedfs-mount"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "seaweedfs-mount" })
  }

  spec {
    selector {
      match_labels = { app = local.app_name, component = "seaweedfs-mount" }
    }

    strategy {
      type = "OnDelete"
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "seaweedfs-mount" })
      }

      spec {
        service_account_name = kubernetes_service_account.csi.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        # The mount service. At startup it reconciles any stale fuse.seaweedfs
        # mounts left by a prior instance, then listens on the shared socket
        # for mount/unmount RPCs from csi-seaweedfs.
        container {
          name              = "seaweedfs-mount"
          image             = "registry.brmartin.co.uk/ben/seaweedfs-mount:${var.csi_mount_image_tag}"
          image_pull_policy = "IfNotPresent"

          args = [
            "--endpoint=$(MOUNT_ENDPOINT)",
          ]

          env {
            name  = "MOUNT_ENDPOINT"
            value = "unix:///var/lib/seaweedfs-mount/seaweedfs-mount.sock"
          }

          env {
            name  = "GOMEMLIMIT"
            value = "1800MiB"
          }

          security_context {
            privileged = true
          }

          volume_mount {
            name              = "kubelet-plugins"
            mount_path        = "/var/lib/kubelet/plugins"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name              = "kubelet-pods"
            mount_path        = "/var/lib/kubelet/pods"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name       = "mount-socket"
            mount_path = "/var/lib/seaweedfs-mount"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/seaweedfs"
          }

          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "2Gi"
            }
          }
        }

        volume {
          name = "kubelet-plugins"
          host_path {
            path = "/var/lib/kubelet/plugins"
            type = "Directory"
          }
        }

        volume {
          name = "kubelet-pods"
          host_path {
            path = "/var/lib/kubelet/pods"
            type = "Directory"
          }
        }

        volume {
          name = "mount-socket"
          host_path {
            path = "/var/lib/seaweedfs-mount"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "cache"
          host_path {
            path = "/var/cache/seaweedfs"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "dev"
          host_path {
            path = "/dev"
          }
        }
      }
    }
  }
}
```

- [ ] **Step 4.6: terraform fmt + validate**

```bash
cd ~/Documents/Personal/projects/iac/cluster-state
terraform fmt modules-k8s/seaweedfs/csi.tf
terraform validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4.7: terraform plan and review carefully**

```bash
cd ~/Documents/Personal/projects/iac/cluster-state
terraform plan -out=/tmp/seaweedfs-split.plan 2>&1 | tee /tmp/seaweedfs-split.plan.txt
grep -E '^\s*[+~-]' /tmp/seaweedfs-split.plan.txt | head -80
```
Expected changes:
- `kubernetes_daemon_set_v1.seaweedfs_mount` — **create** (new resource)
- `kubernetes_daemon_set_v1.csi_node` — **update in place** (container removed, init container removed, 2 volumes change from emptyDir to hostPath)
- Image tag env vars may show as recreated container spec — that's fine.

**Do NOT apply yet.** Human review required before Task 5.

---

## Task 5: Apply + cycle consumers (DISRUPTIVE)

**Files:** none (runtime)

**Context:** This is the disruptive step. `terraform apply` will:
1. Create the new `seaweedfs-mount` DaemonSet → 3 new pods, each runs reconcile at startup.
2. Update `seaweedfs-csi-node` in-place: the existing container `seaweedfs-mount` is removed → k3s terminates the whole old pod and creates a new one per node → all in-pod weed mount subprocesses die → every FUSE session on every node becomes ENOTCONN simultaneously.
3. The new `seaweedfs-mount` DaemonSet pods start and reconcile any leftover stale mounts.
4. The new `csi-node` pods start and connect to the new socket path.
5. **All consumer pods on all nodes are left with stale bind mounts**. Kubelet does not auto-recover them. Step 5.3 cycles them explicitly.

- [ ] **Step 5.1: Pre-apply baseline probe (so we can confirm post-apply state was the expected kind of broken)**

```bash
kubectl get pods -A -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Running") as $p | ($p.spec.volumes // [])[] | select(.persistentVolumeClaim) | "\($p.metadata.namespace)/\($p.metadata.name)"' | sort -u > /tmp/pvc-pods-pre.txt
wc -l /tmp/pvc-pods-pre.txt
```
Expected: ~21 pods (approximate — depends on current cluster state).

- [ ] **Step 5.2: Apply**

```bash
cd ~/Documents/Personal/projects/iac/cluster-state
terraform apply /tmp/seaweedfs-split.plan
```
Expected: `Apply complete! Resources: 1 added, 1 changed, 0 destroyed.`
Wait 60 seconds, then:

```bash
kubectl -n default get ds seaweedfs-csi-node seaweedfs-mount
kubectl -n default get pod -l component=seaweedfs-mount -o wide
kubectl -n default get pod -l component=csi-node -o wide
```
Expected: both DaemonSets show `3` desired / `3` ready. 3 `seaweedfs-mount-*` pods (one per node) and 3 `seaweedfs-csi-node-*` pods.

- [ ] **Step 5.3: Confirm reconcile fired on all 3 new mount pods**

```bash
for pod in $(kubectl -n default get pod -l component=seaweedfs-mount -o name); do
  echo "=== $pod ==="
  kubectl -n default logs $pod | grep reconcile | head -3
done
```
Expected: each pod logs `reconcile: found N fuse.seaweedfs mount(s), lazy-unmounting unconditionally` (N will vary per node based on how many PVCs are bound there).

- [ ] **Step 5.4: Cycle all consumer pods**

```bash
while IFS=/ read ns name; do
  kubectl -n "$ns" delete pod "$name" --wait=false
done < /tmp/pvc-pods-pre.txt
```
Wait for all replacement pods to be Ready:
```bash
sleep 120
kubectl get pods -A -o wide | /bin/grep -v Running | /bin/grep -v Completed
```
Expected: no PVC consumer pods stuck pending/not-ready. (gitlab-* may take longer — re-check after another 60s if needed.)

- [ ] **Step 5.5: Static probe — cluster-wide**

```bash
kubectl get pods -A -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Running") as $p | ($p.spec.volumes // [])[] | select(.persistentVolumeClaim) | "\($p.metadata.namespace)/\($p.metadata.name)"' | sort -u > /tmp/pvc-pods.txt

while IFS=/ read ns name; do
  containers=$(kubectl get pod -n "$ns" "$name" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null)
  for c in $containers; do
    out=$(kubectl exec -n "$ns" "$name" -c "$c" -- sh -c '
      awk "/fuse.seaweedfs/ {print \$5}" /proc/self/mountinfo 2>/dev/null | while read mp; do
        stat "$mp" >/dev/null 2>&1 || echo "BROKEN:$mp"
      done
    ' 2>/dev/null)
    [ -n "$out" ] && echo "$ns/$name[$c]  $out"
  done
done < /tmp/pvc-pods.txt
echo "---DONE---"
```
Expected: only `---DONE---` line. Zero broken mounts. If any pod is still broken, `kubectl delete` it and re-probe.

---

## Task 6: Verify the split actually decouples csi-node from mounts

**Files:** none

**Context:** The whole point of this change is that `seaweedfs-csi-node` can restart without breaking consumers. This verification test proves it.

- [ ] **Step 6.1: Pick a node and capture its pre-test state**

```bash
POD=$(kubectl -n default get pod -l component=csi-node -o wide --no-headers | /bin/grep nyx | awk '{print $1}')
NODE=nyx
echo "Will delete $POD on $NODE"
kubectl get pods -A -o json 2>/dev/null | jq -r --arg node "$NODE" '.items[] | select(.status.phase=="Running" and .spec.nodeName==$node) as $p | select(($p.spec.volumes // []) | map(select(.persistentVolumeClaim)) | length > 0) | "\($p.metadata.namespace)/\($p.metadata.name)"' > /tmp/nyx-consumers.txt
cat /tmp/nyx-consumers.txt
```

- [ ] **Step 6.2: Baseline probe on nyx consumers**

```bash
while IFS=/ read ns name; do
  kubectl exec -n "$ns" "$name" -- sh -c '
    awk "/fuse.seaweedfs/ {print \$5}" /proc/self/mountinfo 2>/dev/null | while read mp; do
      stat "$mp" >/dev/null 2>&1 && echo "OK:$mp" || echo "BROKEN:$mp"
    done
  ' 2>/dev/null | sed "s|^|$ns/$name  |"
done < /tmp/nyx-consumers.txt
```
Expected: all OK.

- [ ] **Step 6.3: Delete the csi-node pod on nyx**

```bash
kubectl -n default delete pod $POD
sleep 60
kubectl -n default get pod -l component=csi-node -o wide | /bin/grep nyx
```
Expected: new pod running on nyx.

- [ ] **Step 6.4: Re-probe — consumers should still be fine**

Re-run the probe from Step 6.2. **Expected: all OK, zero BROKEN.** This is the key success criterion. If any are broken, the split failed and we need to debug (likely socket path or hostPath issue).

- [ ] **Step 6.5: Also confirm seaweedfs-mount pod was NOT restarted**

```bash
kubectl -n default get pod -l component=seaweedfs-mount -o wide
```
Expected: the nyx seaweedfs-mount pod has the original age (not seconds-old).

---

## Task 7: Commit terraform changes

**Files:** `csi.tf`, `variables.tf`

- [ ] **Step 7.1: Stage and commit**

```bash
cd ~/Documents/Personal/projects/iac/cluster-state
git add modules-k8s/seaweedfs/csi.tf modules-k8s/seaweedfs/variables.tf
git commit -m "$(cat <<'EOF'
seaweedfs: split seaweedfs-mount into its own DaemonSet

Decouples the FUSE daemon from the CSI driver pod lifecycle. Before:
restarting seaweedfs-csi-node (for any reason — driver upgrade,
registrar update, crashloop, liveness failure) killed the in-pod
seaweedfs-mount sidecar, taking down every weed mount subprocess and
leaving all consumer pods on the node with ENOTCONN bind mounts.

Now seaweedfs-mount lives in its own DaemonSet with OnDelete update
strategy: its lifecycle is independent of the CSI driver, and restarts
are an explicit operator action (paired with consumer cycling).

- mount-socket and cache volumes move from emptyDir to hostPath so
  both DaemonSets see the same /var/lib/seaweedfs-mount and
  /var/cache/seaweedfs
- cleanup-stale-mounts init container is removed; its job is now done
  unconditionally by reconcile.go in the new mount service image
- Image tags bumped to v1.4.8-split (includes reconcile race fix —
  unconditional unmount at startup)

Verification: csi-node pod can now be deleted without disturbing
consumer mounts on the same node.
EOF
)"
```

---

## Task 8: Update memory + cleanup

**Files:**
- Modify: `/home/ben/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/project_seaweedfs_reconcile_propagation_2026_04_08.md`
- Modify: `/home/ben/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/MEMORY.md`
- Delete: `/tmp/seaweedfs-csi-deploy-handoff.md`
- Delete: `~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/*.tar`

- [ ] **Step 8.1: Rewrite the memory file to reflect the final shipped state**

Update `project_seaweedfs_reconcile_propagation_2026_04_08.md` so it no longer describes a broken in-progress state. Summarise: split shipped; csi-node can restart without disturbing mounts; seaweedfs-mount is `OnDelete`, restarting it still requires consumer cycling; reconcile race fixed. Update the MEMORY.md pointer line accordingly.

- [ ] **Step 8.2: Delete handoff artifacts**

```bash
rm /tmp/seaweedfs-csi-deploy-handoff.md
rm ~/Documents/Personal/projects/seaweedfs-csi-driver/_output/deploy/*.tar
```

---

## Rollback plan (if Task 5 fails catastrophically)

If `terraform apply` leaves the cluster in a worse state than the pre-apply disruption (e.g. new DaemonSet fails to start, socket path broken, new driver binary crashes):

1. Revert terraform changes: `git checkout modules-k8s/seaweedfs/csi.tf modules-k8s/seaweedfs/variables.tf`
2. `terraform apply` — this restores the old `v1.4.7-reconcile` DaemonSet with the inline mount container.
3. All consumer pods still need a cycle (the original in-pod mount sessions died during the failed apply). Re-run the delete loop from Step 5.4.
4. Root-cause the failure before retrying.

The old images are still on every node in containerd; no image fetch needed for rollback.

---

## Self-Review Notes

Coverage check against the goal:
- [x] Bug 1 fix (reconcile race) — Task 1
- [x] Image rebuild + sideload — Task 2
- [x] Terraform restructure (split DS + hostPath volumes) — Tasks 3, 4
- [x] Safe apply path with explicit consumer cycling — Task 5
- [x] Success test (csi-node restart does not break mounts) — Task 6
- [x] Commit — Task 7
- [x] Memory update + artifact cleanup — Task 8
- [x] Rollback plan
