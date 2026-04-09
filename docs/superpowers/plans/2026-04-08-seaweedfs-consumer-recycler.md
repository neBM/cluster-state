# SeaweedFS Consumer Recycler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy an in-cluster DaemonSet that automatically cycles consumer pods when `seaweedfs-mount` restarts or a FUSE mount goes bad on their node, removing the manual `kubectl delete pod` workflow documented as Gap #2 in `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`.

**Architecture:** Per-node Go DaemonSet built on `sigs.k8s.io/controller-runtime`. Two signal sources feed one reconcile work queue: a filtered Pod informer for `seaweedfs-mount` restart detection (Path A), and a 30-second ticker that `stat`s every `fuse.seaweedfs` mountpoint in a 2-second subprocess (Path B). Candidate consumers are enumerated by matching `PV.Spec.CSI.Driver == "seaweedfs-csi-driver"` on each pod's PVCs and cycled via eviction-first (fall back to force-delete after 30s of PDB blocks) with a 5-second stagger and a 120s debounce map. Cold-start safety is layered: first observation of a mount-daemon pod UID just records the baseline (no action), and Path A is suppressed for the first 60s after recycler startup (probe handles genuine breakage during that window).

**Tech Stack:** Go 1.25, `sigs.k8s.io/controller-runtime` v0.20.x, `k8s.io/client-go` v0.32.0, `github.com/prometheus/client_golang` (already transitive in `go.mod`). Terraform `kubernetes` + `kubectl` providers (existing in `modules-k8s/seaweedfs/`). CI via GitLab on `drivers/**` path changes.

**Spec reference:** `docs/superpowers/specs/2026-04-08-seaweedfs-consumer-recycler-design.md`. Read this before starting — it contains the full "why" for every design decision. This plan is the "how".

---

## File Structure

**New Go files (under `drivers/seaweedfs-csi-driver/`):**
- `cmd/seaweedfs-consumer-recycler/main.go` — flag parsing, manager wiring, signal handling (~120 lines)
- `cmd/seaweedfs-consumer-recycler/Dockerfile` — multi-stage build (mirrors `cmd/seaweedfs-mount/Dockerfile` pattern)
- `pkg/recycler/pvlookup.go` — pod→PVC→PV→driver match (~80 lines)
- `pkg/recycler/pvlookup_test.go` — table-driven unit tests
- `pkg/recycler/startup.go` — per-UID baseline snapshot + cold-start grace window (~60 lines)
- `pkg/recycler/startup_test.go` — transition table tests
- `pkg/recycler/cycler.go` — eviction-first cycling, debounce, stagger (~140 lines)
- `pkg/recycler/cycler_test.go` — fake-client tests for 200/429/fallback
- `pkg/recycler/prober.go` — mountinfo scan + subprocess `stat` with timeout (~100 lines)
- `pkg/recycler/prober_test.go` — tmpdir `/proc` + injected fake `stat` binary
- `pkg/recycler/reconciler.go` — controller-runtime `Reconciler` implementation (~80 lines)
- `pkg/recycler/reconciler_test.go` — envtest integration test
- `pkg/recycler/metrics.go` — Prometheus metric definitions (~40 lines)

**Modified Go files:**
- `drivers/seaweedfs-csi-driver/go.mod` — add `sigs.k8s.io/controller-runtime` direct dep, promote `k8s.io/api`, `k8s.io/apimachinery`, `github.com/prometheus/client_golang` to direct
- `drivers/seaweedfs-csi-driver/Makefile` — add `seaweedfs-consumer-recycler` binary + container targets

**New Terraform files:**
- `modules-k8s/seaweedfs/consumer-recycler.tf` — ServiceAccount, ClusterRole, ClusterRoleBinding, DaemonSet, Service with Prometheus scrape annotations (~220 lines HCL)

**Modified Terraform files:**
- `modules-k8s/seaweedfs/variables.tf` — add `consumer_recycler_image_tag` variable

**Modified CI files:**
- `.gitlab-ci.yml` — add `drivers-build` stage gated on `rules:changes: drivers/**`

---

## Task 1: Scaffold package layout and dependencies

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/go.mod`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/doc.go`
- Create: `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/doc.go`

- [ ] **Step 1: Create package doc files**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/doc.go`:
```go
// Package recycler implements per-node detection and remediation of broken
// fuse.seaweedfs mounts and seaweedfs-mount pod restarts. See
// docs/superpowers/specs/2026-04-08-seaweedfs-consumer-recycler-design.md
// for the full design.
package recycler
```

Create `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/doc.go`:
```go
// Command seaweedfs-consumer-recycler runs as a per-node DaemonSet that
// cycles consumer pods when their FUSE mounts become unusable.
package main
```

- [ ] **Step 2: Add controller-runtime and direct dependencies**

Run (from `drivers/seaweedfs-csi-driver/`):
```bash
cd drivers/seaweedfs-csi-driver
go get sigs.k8s.io/controller-runtime@v0.20.4
go get k8s.io/api@v0.32.0
go get k8s.io/apimachinery@v0.32.0
go get github.com/prometheus/client_golang@v1.23.2
go mod tidy
```

Expected: `go.mod` now has `sigs.k8s.io/controller-runtime v0.20.4` as a direct require, plus `k8s.io/api`, `k8s.io/apimachinery`, `prometheus/client_golang` promoted from indirect.

- [ ] **Step 3: Verify build still works**

Run: `go build ./...`
Expected: exits 0, no errors. Existing driver + mount binaries still compile.

- [ ] **Step 4: Commit**

```bash
git add drivers/seaweedfs-csi-driver/go.mod drivers/seaweedfs-csi-driver/go.sum drivers/seaweedfs-csi-driver/pkg/recycler/doc.go drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/doc.go
git commit -m "feat(recycler): scaffold package layout + controller-runtime dep"
```

---

## Task 2: pvlookup — pod→driver match

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/pvlookup.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/pvlookup_test.go`

- [ ] **Step 1: Write failing unit tests**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/pvlookup_test.go`:
```go
package recycler

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const csiDriverName = "seaweedfs-csi-driver"

func newFakeClient(objs ...client.Object) client.Client {
	return fake.NewClientBuilder().WithObjects(objs...).Build()
}

func pod(name, node string, pvcs ...string) *corev1.Pod {
	vols := make([]corev1.Volume, 0, len(pvcs))
	for _, p := range pvcs {
		vols = append(vols, corev1.Volume{
			Name: p,
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: p},
			},
		})
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default", UID: pkUID(name)},
		Spec:       corev1.PodSpec{NodeName: node, Volumes: vols},
		Status:     corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

func pvc(name, pvName string) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       corev1.PersistentVolumeClaimSpec{VolumeName: pvName},
	}
}

func pv(name, driver string) *corev1.PersistentVolume {
	return &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: corev1.PersistentVolumeSpec{
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				CSI: &corev1.CSIPersistentVolumeSource{Driver: driver},
			},
		},
	}
}

func pkUID(name string) types.UID { return types.UID("uid-" + name) }

func TestListCandidates_MatchesOnlySeaweedCSI(t *testing.T) {
	ctx := context.Background()
	c := newFakeClient(
		pod("app1", "nyx", "app1-data"),
		pvc("app1-data", "pv-1"),
		pv("pv-1", csiDriverName),

		pod("app2", "nyx", "app2-data"),
		pvc("app2-data", "pv-2"),
		pv("pv-2", "other.csi.driver"),

		pod("app3", "heracles", "app3-data"),
		pvc("app3-data", "pv-3"),
		pv("pv-3", csiDriverName),
	)

	lookup := &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName}
	got, err := lookup.ListCandidates(ctx)
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 1 || got[0].Name != "app1" {
		t.Fatalf("want [app1], got %v", got)
	}
}

func TestListCandidates_SkipsTerminating(t *testing.T) {
	now := metav1.Now()
	p := pod("app1", "nyx", "app1-data")
	p.DeletionTimestamp = &now
	c := newFakeClient(p, pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName))
	lookup := &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName}
	got, err := lookup.ListCandidates(context.Background())
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("want no candidates, got %v", got)
	}
}

func TestListCandidates_SkipsMountDaemonAndRecycler(t *testing.T) {
	mp := pod("seaweedfs-mount-abc", "nyx")
	mp.Labels = map[string]string{"component": "seaweedfs-mount"}
	rp := pod("seaweedfs-consumer-recycler-xyz", "nyx")
	rp.Labels = map[string]string{"app.kubernetes.io/name": "seaweedfs-consumer-recycler"}
	c := newFakeClient(mp, rp)
	lookup := &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName}
	got, err := lookup.ListCandidates(context.Background())
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("want no candidates, got %v", got)
	}
}
```

Add missing import to top of test file: `"k8s.io/apimachinery/pkg/types"`.

- [ ] **Step 2: Run tests (expect compile failure)**

Run: `go test ./pkg/recycler/... -run TestListCandidates -v`
Expected: FAIL with "undefined: PVLookup".

- [ ] **Step 3: Implement `PVLookup`**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/pvlookup.go`:
```go
package recycler

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/fields"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PVLookup enumerates consumer pods on NodeName that hold at least one PVC
// whose bound PV is served by the CSI driver named Driver. Candidates exclude
// pods already Terminating, the seaweedfs-mount DaemonSet pods, and the
// recycler's own pods.
type PVLookup struct {
	Client   client.Client
	NodeName string
	Driver   string
}

// ListCandidates returns the filtered candidate pods for reconciliation.
func (l *PVLookup) ListCandidates(ctx context.Context) ([]corev1.Pod, error) {
	var pods corev1.PodList
	if err := l.Client.List(ctx, &pods, &client.ListOptions{
		FieldSelector: fields.OneTermEqualSelector("spec.nodeName", l.NodeName),
	}); err != nil {
		return nil, fmt.Errorf("list pods on %q: %w", l.NodeName, err)
	}

	var out []corev1.Pod
	for i := range pods.Items {
		p := &pods.Items[i]
		if p.DeletionTimestamp != nil {
			continue
		}
		if p.Labels["component"] == "seaweedfs-mount" {
			continue
		}
		if p.Labels["app.kubernetes.io/name"] == "seaweedfs-consumer-recycler" {
			continue
		}
		uses, err := l.podUsesDriver(ctx, p)
		if err != nil {
			return nil, err
		}
		if uses {
			out = append(out, *p)
		}
	}
	return out, nil
}

func (l *PVLookup) podUsesDriver(ctx context.Context, p *corev1.Pod) (bool, error) {
	for _, v := range p.Spec.Volumes {
		if v.PersistentVolumeClaim == nil {
			continue
		}
		var pvc corev1.PersistentVolumeClaim
		key := client.ObjectKey{Namespace: p.Namespace, Name: v.PersistentVolumeClaim.ClaimName}
		if err := l.Client.Get(ctx, key, &pvc); err != nil {
			// PVC gone — pod will eventually be terminated by kubelet; skip.
			continue
		}
		if pvc.Spec.VolumeName == "" {
			continue
		}
		var pv corev1.PersistentVolume
		if err := l.Client.Get(ctx, client.ObjectKey{Name: pvc.Spec.VolumeName}, &pv); err != nil {
			continue
		}
		if pv.Spec.CSI != nil && pv.Spec.CSI.Driver == l.Driver {
			return true, nil
		}
	}
	return false, nil
}

// ResolvePodFromMountpoint parses a kubelet CSI mount path of the form
// /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc-name>/mount
// and returns the pod UID segment. Returns "" if the path doesn't match.
func ResolvePodUIDFromMountpoint(mountpoint string) string {
	const prefix = "/var/lib/kubelet/pods/"
	if len(mountpoint) <= len(prefix) || mountpoint[:len(prefix)] != prefix {
		return ""
	}
	rest := mountpoint[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' {
			return rest[:i]
		}
	}
	return ""
}
```

- [ ] **Step 4: Run tests (expect pass)**

Run: `go test ./pkg/recycler/... -run TestListCandidates -v`
Expected: PASS on all three subtests.

- [ ] **Step 5: Add test for `ResolvePodUIDFromMountpoint`**

Append to `pvlookup_test.go`:
```go
func TestResolvePodUIDFromMountpoint(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"/var/lib/kubelet/pods/abc-123/volumes/kubernetes.io~csi/pvc-1/mount", "abc-123"},
		{"/var/lib/kubelet/pods/xyz/volumes/kubernetes.io~csi/pvc/mount", "xyz"},
		{"/somewhere/else", ""},
		{"/var/lib/kubelet/pods/", ""},
	}
	for _, tc := range cases {
		if got := ResolvePodUIDFromMountpoint(tc.in); got != tc.want {
			t.Errorf("ResolvePodUIDFromMountpoint(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
```

Run: `go test ./pkg/recycler/... -v`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/recycler/pvlookup.go drivers/seaweedfs-csi-driver/pkg/recycler/pvlookup_test.go
git commit -m "feat(recycler): PVLookup resolves pods by CSI driver name"
```

---

## Task 3: startup — baseline snapshot + cold-start grace

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/startup.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/startup_test.go`

- [ ] **Step 1: Write failing tests**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/startup_test.go`:
```go
package recycler

import (
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/types"
)

func TestBaselineTracker_FirstObservationNeverTriggers(t *testing.T) {
	bt := NewBaselineTracker()
	if bt.ObserveRestart("uid1", 0) {
		t.Fatal("first observation must not trigger")
	}
}

func TestBaselineTracker_RestartCountBumpTriggers(t *testing.T) {
	bt := NewBaselineTracker()
	bt.ObserveRestart("uid1", 0)
	if !bt.ObserveRestart("uid1", 1) {
		t.Fatal("incremented restart count must trigger")
	}
}

func TestBaselineTracker_UIDChangeTriggers(t *testing.T) {
	bt := NewBaselineTracker()
	bt.ObserveRestart("uid1", 3)
	if !bt.ObserveRestart("uid2", 0) {
		t.Fatal("new UID must trigger")
	}
}

func TestBaselineTracker_SameStateDoesNotTrigger(t *testing.T) {
	bt := NewBaselineTracker()
	bt.ObserveRestart("uid1", 5)
	if bt.ObserveRestart("uid1", 5) {
		t.Fatal("no-change observation must not trigger")
	}
}

func TestColdStartWindow_SuppressesPathADuringGrace(t *testing.T) {
	w := NewColdStartWindow(60 * time.Second)
	if !w.Suppressed(w.startedAt.Add(30 * time.Second)) {
		t.Fatal("should suppress within grace window")
	}
	if w.Suppressed(w.startedAt.Add(61 * time.Second)) {
		t.Fatal("should not suppress after grace window")
	}
}
```

- [ ] **Step 2: Run tests (expect fail)**

Run: `go test ./pkg/recycler/... -run "TestBaselineTracker|TestColdStartWindow" -v`
Expected: FAIL with "undefined: NewBaselineTracker".

- [ ] **Step 3: Implement startup.go**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/startup.go`:
```go
package recycler

import (
	"sync"
	"time"

	"k8s.io/apimachinery/pkg/types"
)

// BaselineTracker remembers the most recently observed {UID, RestartCount}
// tuple per seaweedfs-mount pod so we can detect the NEXT restart without
// false-firing on the FIRST observation after recycler startup.
type BaselineTracker struct {
	mu       sync.Mutex
	baseline map[types.UID]int32
}

func NewBaselineTracker() *BaselineTracker {
	return &BaselineTracker{baseline: map[types.UID]int32{}}
}

// ObserveRestart records (uid, restartCount) and returns true iff this
// observation represents a restart relative to the stored baseline.
func (b *BaselineTracker) ObserveRestart(uid types.UID, restartCount int32) bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	prev, seen := b.baseline[uid]
	b.baseline[uid] = restartCount

	if !seen {
		// First observation of this UID.
		// If we had a previous UID that is now gone, the caller should have
		// already handled it via the informer's delete event. Here we only
		// record — no retroactive triggering.
		return false
	}
	return restartCount > prev
}

// Forget removes a UID from the baseline map (call on pod delete events).
func (b *BaselineTracker) Forget(uid types.UID) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.baseline, uid)
}

// ColdStartWindow suppresses Path A triggers for the first `grace` duration
// after recycler startup. Path B (the prober) is unaffected.
type ColdStartWindow struct {
	startedAt time.Time
	grace     time.Duration
}

func NewColdStartWindow(grace time.Duration) *ColdStartWindow {
	return &ColdStartWindow{startedAt: time.Now(), grace: grace}
}

// Suppressed reports whether Path A should be suppressed at time `now`.
func (w *ColdStartWindow) Suppressed(now time.Time) bool {
	return now.Before(w.startedAt.Add(w.grace))
}
```

- [ ] **Step 4: Run tests (expect pass)**

Run: `go test ./pkg/recycler/... -v`
Expected: all tests PASS including new ones.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/recycler/startup.go drivers/seaweedfs-csi-driver/pkg/recycler/startup_test.go
git commit -m "feat(recycler): baseline tracker + cold-start grace window"
```

---

## Task 4: cycler — eviction-first with fallback, debounce, stagger

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/cycler.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/cycler_test.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/metrics.go`

- [ ] **Step 1: Implement metrics.go (no tests — definitions only)**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/metrics.go`:
```go
package recycler

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	TriggersTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_triggers_total",
			Help: "Number of reconcile triggers by signal path.",
		},
		[]string{"path"}, // "event" | "probe"
	)
	CyclesTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_cycles_total",
			Help: "Consumer pod cycles by outcome.",
		},
		[]string{"outcome"}, // "evicted" | "forced" | "skipped_debounce" | "error"
	)
	ProbeDurationSeconds = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "seaweedfs_recycler_probe_duration_seconds",
			Help:    "Duration of a full prober sweep.",
			Buckets: prometheus.DefBuckets,
		},
	)
	ProbeFailuresTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_probe_failures_total",
			Help: "Probe failures by reason.",
		},
		[]string{"reason"}, // "stat-timeout" | "stat-error" | "mountinfo-read"
	)
	ColdStartSuppressedTotal = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_cold_start_suppressed_total",
			Help: "Path A triggers suppressed by the cold-start window.",
		},
	)
	EvictionBlockedTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_eviction_blocked_total",
			Help: "Eviction calls blocked before fallback.",
		},
		[]string{"reason"}, // "pdb" | "other"
	)
)

func init() {
	metrics.Registry.MustRegister(
		TriggersTotal,
		CyclesTotal,
		ProbeDurationSeconds,
		ProbeFailuresTotal,
		ColdStartSuppressedTotal,
		EvictionBlockedTotal,
	)
}
```

- [ ] **Step 2: Write failing cycler tests**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/cycler_test.go`:
```go
package recycler

import (
	"context"
	"errors"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// fakeEvictor records eviction attempts and can be scripted to return errors.
type fakeEvictor struct {
	attempts  []types.NamespacedName
	errorFunc func(attempt int) error
	deletes   []types.NamespacedName
}

func (f *fakeEvictor) Evict(ctx context.Context, pod *corev1.Pod) error {
	f.attempts = append(f.attempts, types.NamespacedName{Namespace: pod.Namespace, Name: pod.Name})
	if f.errorFunc != nil {
		return f.errorFunc(len(f.attempts))
	}
	return nil
}

func (f *fakeEvictor) ForceDelete(ctx context.Context, pod *corev1.Pod) error {
	f.deletes = append(f.deletes, types.NamespacedName{Namespace: pod.Namespace, Name: pod.Name})
	return nil
}

func TestCycler_EvictsSuccess(t *testing.T) {
	ev := &fakeEvictor{}
	c := &Cycler{
		Evictor:       ev,
		Stagger:       0,
		Debounce:      NewDebouncer(time.Minute),
		EvictionRetry: 10 * time.Millisecond,
		EvictionDeadline: 100 * time.Millisecond,
	}
	p := pod("app1", "nyx", "d1")
	if err := c.CycleOne(context.Background(), p); err != nil {
		t.Fatalf("CycleOne: %v", err)
	}
	if len(ev.attempts) != 1 {
		t.Fatalf("want 1 attempt, got %d", len(ev.attempts))
	}
	if len(ev.deletes) != 0 {
		t.Fatalf("want no force-deletes, got %d", len(ev.deletes))
	}
}

func TestCycler_PDBFallbackAfterDeadline(t *testing.T) {
	ev := &fakeEvictor{
		errorFunc: func(attempt int) error {
			return apierrors.NewTooManyRequests("pdb", 0)
		},
	}
	c := &Cycler{
		Evictor:          ev,
		Stagger:          0,
		Debounce:         NewDebouncer(time.Minute),
		EvictionRetry:    10 * time.Millisecond,
		EvictionDeadline: 50 * time.Millisecond,
	}
	p := pod("app1", "nyx", "d1")
	if err := c.CycleOne(context.Background(), p); err != nil {
		t.Fatalf("CycleOne: %v", err)
	}
	if len(ev.attempts) < 2 {
		t.Fatalf("want >= 2 eviction attempts, got %d", len(ev.attempts))
	}
	if len(ev.deletes) != 1 {
		t.Fatalf("want 1 force-delete, got %d", len(ev.deletes))
	}
}

func TestCycler_Debounce(t *testing.T) {
	ev := &fakeEvictor{}
	d := NewDebouncer(time.Minute)
	c := &Cycler{
		Evictor:          ev,
		Stagger:          0,
		Debounce:         d,
		EvictionRetry:    10 * time.Millisecond,
		EvictionDeadline: 100 * time.Millisecond,
	}
	p := pod("app1", "nyx", "d1")
	_ = c.CycleOne(context.Background(), p)
	_ = c.CycleOne(context.Background(), p)
	if len(ev.attempts) != 1 {
		t.Fatalf("want 1 attempt due to debounce, got %d", len(ev.attempts))
	}
}

// helper: make apierrors.IsTooManyRequests observable
var _ = errors.New
var _ = schema.GroupResource{}
var _ = client.Object(nil)
var _ = fake.NewClientBuilder
var _ = &policyv1.Eviction{}
var _ = &metav1.DeleteOptions{}
```

- [ ] **Step 3: Run tests (expect fail)**

Run: `go test ./pkg/recycler/... -run TestCycler -v`
Expected: FAIL with "undefined: Cycler".

- [ ] **Step 4: Implement cycler.go**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/cycler.go`:
```go
package recycler

import (
	"context"
	"fmt"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
)

// Evictor is the minimal API the cycler needs, separated from the real k8s
// client so tests can substitute fakes. Production impl is KubeEvictor below.
type Evictor interface {
	Evict(ctx context.Context, pod *corev1.Pod) error
	ForceDelete(ctx context.Context, pod *corev1.Pod) error
}

// Cycler orchestrates eviction-first, fallback-to-force-delete cycling of a
// single pod, honoring a debounce map.
type Cycler struct {
	Evictor          Evictor
	Debounce         *Debouncer
	Stagger          time.Duration
	EvictionRetry    time.Duration
	EvictionDeadline time.Duration
}

// CycleOne cycles a single candidate pod. Idempotent against the debounce
// map: consecutive calls with the same pod UID within the debounce window
// are no-ops.
func (c *Cycler) CycleOne(ctx context.Context, pod *corev1.Pod) error {
	if c.Debounce.Skip(pod.UID) {
		CyclesTotal.WithLabelValues("skipped_debounce").Inc()
		return nil
	}

	deadline := time.Now().Add(c.EvictionDeadline)
	for {
		err := c.Evictor.Evict(ctx, pod)
		if err == nil {
			c.Debounce.Mark(pod.UID)
			CyclesTotal.WithLabelValues("evicted").Inc()
			return nil
		}
		if !apierrors.IsTooManyRequests(err) {
			CyclesTotal.WithLabelValues("error").Inc()
			return fmt.Errorf("evict %s/%s: %w", pod.Namespace, pod.Name, err)
		}
		EvictionBlockedTotal.WithLabelValues("pdb").Inc()
		if time.Now().After(deadline) {
			if derr := c.Evictor.ForceDelete(ctx, pod); derr != nil {
				CyclesTotal.WithLabelValues("error").Inc()
				return fmt.Errorf("force-delete %s/%s: %w", pod.Namespace, pod.Name, derr)
			}
			c.Debounce.Mark(pod.UID)
			CyclesTotal.WithLabelValues("forced").Inc()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(c.EvictionRetry):
		}
	}
}

// CycleBatch cycles all pods in `candidates`, sleeping `Stagger` between each.
// Errors are logged but do not abort the batch — we want to make forward
// progress on as many as possible in one reconcile pass.
func (c *Cycler) CycleBatch(ctx context.Context, candidates []corev1.Pod) {
	for i := range candidates {
		if err := c.CycleOne(ctx, &candidates[i]); err != nil {
			// Caller should attach logr and log — we don't import logging here.
			_ = err
		}
		if i < len(candidates)-1 && c.Stagger > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(c.Stagger):
			}
		}
	}
}

// Debouncer tracks pod UIDs that have been cycled recently so we skip them.
type Debouncer struct {
	mu  sync.Mutex
	ttl time.Duration
	m   map[types.UID]time.Time
}

func NewDebouncer(ttl time.Duration) *Debouncer {
	return &Debouncer{ttl: ttl, m: map[types.UID]time.Time{}}
}

func (d *Debouncer) Skip(uid types.UID) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	t, ok := d.m[uid]
	if !ok {
		return false
	}
	if time.Since(t) >= d.ttl {
		delete(d.m, uid)
		return false
	}
	return true
}

func (d *Debouncer) Mark(uid types.UID) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.m[uid] = time.Now()
}

// KubeEvictor is the production implementation of Evictor backed by the real
// client-go clientset (to reach the pods/eviction subresource).
type KubeEvictor struct {
	Clientset kubernetes.Interface
}

func (k *KubeEvictor) Evict(ctx context.Context, pod *corev1.Pod) error {
	return k.Clientset.PolicyV1().Evictions(pod.Namespace).Evict(ctx, &policyv1.Eviction{
		ObjectMeta: metav1.ObjectMeta{Name: pod.Name, Namespace: pod.Namespace},
	})
}

func (k *KubeEvictor) ForceDelete(ctx context.Context, pod *corev1.Pod) error {
	zero := int64(0)
	return k.Clientset.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{
		GracePeriodSeconds: &zero,
	})
}
```

- [ ] **Step 5: Run tests (expect pass)**

Run: `go test ./pkg/recycler/... -v`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/recycler/cycler.go drivers/seaweedfs-csi-driver/pkg/recycler/cycler_test.go drivers/seaweedfs-csi-driver/pkg/recycler/metrics.go
git commit -m "feat(recycler): eviction-first cycler + debounce + metrics"
```

---

## Task 5: prober — mountinfo scan + subprocess stat

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/prober.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/prober_test.go`

- [ ] **Step 1: Write failing tests**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/prober_test.go`:
```go
package recycler

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseMountinfo_FiltersFuseSeaweedfs(t *testing.T) {
	sample := strings.Join([]string{
		// Standard root mount (filtered out)
		"21 28 0:20 / /sys rw,nosuid,nodev,noexec,relatime shared:7 - sysfs sysfs rw",
		// A fuse.seaweedfs consumer mount (kept)
		"123 45 0:100 / /var/lib/kubelet/pods/abc-1/volumes/kubernetes.io~csi/pvc-one/mount rw,relatime shared:99 - fuse.seaweedfs weed-mount rw",
		// A fuse.seaweedfs mount NOT under a consumer path (filtered out)
		"124 45 0:101 / /tmp/debug rw,relatime shared:100 - fuse.seaweedfs weed-mount rw",
		"",
	}, "\n")

	got := parseMountinfo(sample)
	if len(got) != 1 {
		t.Fatalf("want 1 consumer mount, got %d: %v", len(got), got)
	}
	if got[0] != "/var/lib/kubelet/pods/abc-1/volumes/kubernetes.io~csi/pvc-one/mount" {
		t.Errorf("unexpected mountpoint: %q", got[0])
	}
}

func TestStatProbe_TimesOut(t *testing.T) {
	// Create a fake stat binary that sleeps forever.
	dir := t.TempDir()
	script := filepath.Join(dir, "stat")
	body := "#!/bin/sh\nsleep 30\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	p := &Prober{StatPath: script, StatTimeout: 100 * time.Millisecond}
	err := p.probeOne(context.Background(), "/nonexistent")
	if err == nil {
		t.Fatal("want timeout error, got nil")
	}
}

func TestStatProbe_OK(t *testing.T) {
	p := &Prober{StatPath: "/usr/bin/stat", StatTimeout: 2 * time.Second}
	err := p.probeOne(context.Background(), "/")
	if err != nil {
		t.Fatalf("probeOne(/): %v", err)
	}
}
```

- [ ] **Step 2: Run tests (expect fail)**

Run: `go test ./pkg/recycler/... -run "TestParseMountinfo|TestStatProbe" -v`
Expected: FAIL (undefined `parseMountinfo`, `Prober`).

- [ ] **Step 3: Implement prober.go**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/prober.go`:
```go
package recycler

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultProbeInterval = 30 * time.Second
	defaultStatTimeout   = 2 * time.Second
	kubeletPodsPrefix    = "/var/lib/kubelet/pods/"
)

// Prober runs the periodic /proc/mountinfo + stat probe. Each unhealthy
// mountpoint is forwarded to Trigger as a string.
type Prober struct {
	// Path to the host's /proc (e.g. "/host/proc") — mountinfo is read from
	// <ProcRoot>/self/mountinfo.
	ProcRoot string
	// Path to a stat(1) binary — overridable for tests.
	StatPath string
	// Per-stat timeout; a hung stat subprocess is SIGKILLed on expiry.
	StatTimeout time.Duration
	// Interval between full sweeps.
	Interval time.Duration
	// Trigger is called once per unhealthy mountpoint per tick.
	Trigger func(ctx context.Context, mountpoint string)
}

// Run blocks, running the probe every Interval until ctx is cancelled.
func (p *Prober) Run(ctx context.Context) {
	if p.Interval <= 0 {
		p.Interval = defaultProbeInterval
	}
	if p.StatTimeout <= 0 {
		p.StatTimeout = defaultStatTimeout
	}
	if p.StatPath == "" {
		p.StatPath = "/usr/bin/stat"
	}

	t := time.NewTicker(p.Interval)
	defer t.Stop()
	p.sweep(ctx) // one immediate sweep on startup
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.sweep(ctx)
		}
	}
}

func (p *Prober) sweep(ctx context.Context) {
	start := time.Now()
	defer func() { ProbeDurationSeconds.Observe(time.Since(start).Seconds()) }()

	data, err := os.ReadFile(p.ProcRoot + "/self/mountinfo")
	if err != nil {
		ProbeFailuresTotal.WithLabelValues("mountinfo-read").Inc()
		return
	}
	for _, mp := range parseMountinfo(string(data)) {
		if err := p.probeOne(ctx, mp); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				ProbeFailuresTotal.WithLabelValues("stat-timeout").Inc()
			} else {
				ProbeFailuresTotal.WithLabelValues("stat-error").Inc()
			}
			if p.Trigger != nil {
				p.Trigger(ctx, mp)
			}
		}
	}
}

// probeOne execs `<StatPath> <mountpoint>` with a hard timeout. Returns nil
// on exit 0, an error otherwise (including context.DeadlineExceeded).
func (p *Prober) probeOne(ctx context.Context, mountpoint string) error {
	cctx, cancel := context.WithTimeout(ctx, p.StatTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, p.StatPath, mountpoint)
	if err := cmd.Run(); err != nil {
		if cctx.Err() == context.DeadlineExceeded {
			return context.DeadlineExceeded
		}
		return fmt.Errorf("stat %s: %w", mountpoint, err)
	}
	return nil
}

// parseMountinfo reads /proc/self/mountinfo format and returns the mountpoint
// column for every fuse.seaweedfs mount that lives under kubeletPodsPrefix.
// Format reference: https://man7.org/linux/man-pages/man5/proc.5.html
// Field layout (space-separated): N parent major:minor root mountpoint opts...
// then " - " then fstype source super-opts
func parseMountinfo(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if line == "" {
			continue
		}
		sepIdx := strings.Index(line, " - ")
		if sepIdx < 0 {
			continue
		}
		left := strings.Fields(line[:sepIdx])
		right := strings.Fields(line[sepIdx+3:])
		if len(left) < 5 || len(right) < 1 {
			continue
		}
		mountpoint := left[4]
		fstype := right[0]
		if fstype != "fuse.seaweedfs" {
			continue
		}
		if !strings.HasPrefix(mountpoint, kubeletPodsPrefix) {
			continue
		}
		out = append(out, mountpoint)
	}
	return out
}
```

- [ ] **Step 4: Run tests (expect pass, if `/usr/bin/stat` exists)**

Run: `go test ./pkg/recycler/... -v`
Expected: PASS. If `TestStatProbe_OK` fails with "no such file", change `StatPath` to `/bin/stat` or skip the test on systems without `/usr/bin/stat`.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/recycler/prober.go drivers/seaweedfs-csi-driver/pkg/recycler/prober_test.go
git commit -m "feat(recycler): prober reads mountinfo and subprocess-stats mounts"
```

---

## Task 6: reconciler — controller-runtime Reconciler

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/reconciler.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/recycler/reconciler_test.go`

- [ ] **Step 1: Write failing envtest integration test**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/reconciler_test.go`:
```go
package recycler

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// This is a unit-level test of Reconciler.reconcileRestart using the fake
// client rather than envtest, to keep CI cheap. A true envtest suite can be
// added later if the integration story gets richer.
func TestReconciler_CycleAllCandidatesOnRestart(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-2"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 0, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}

	c := newFakeClient(
		mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
		pod("app2", "nyx", "app2-data"), pvc("app2-data", "pv-2"), pv("pv-2", csiDriverName),
	)

	ev := &fakeEvictor{}
	r := &Reconciler{
		Client:   c,
		NodeName: "nyx",
		Lookup:   &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler: &Cycler{
			Evictor:          ev,
			Debounce:         NewDebouncer(time.Minute),
			EvictionRetry:    1 * time.Millisecond,
			EvictionDeadline: 10 * time.Millisecond,
		},
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	// First observation — records baseline, no cycling.
	r.HandleMountDaemonEvent(context.Background(), mountPod)
	if len(ev.attempts) != 0 {
		t.Fatalf("first observation should not cycle: got %d attempts", len(ev.attempts))
	}

	// Simulate restart.
	mountPod.Status.ContainerStatuses[0].RestartCount = 1
	r.HandleMountDaemonEvent(context.Background(), mountPod)

	if len(ev.attempts) != 2 {
		t.Fatalf("want 2 eviction attempts after restart, got %d", len(ev.attempts))
	}
}

func TestReconciler_ColdStartSuppressesPathA(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-3"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 5, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}
	c := newFakeClient(mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)
	ev := &fakeEvictor{}
	bt := NewBaselineTracker()
	bt.ObserveRestart("mp-uid-3", 5) // pretend we already have a baseline
	r := &Reconciler{
		Client:    c,
		NodeName:  "nyx",
		Lookup:    &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler:    &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Baseline:  bt,
		ColdStart: &ColdStartWindow{startedAt: time.Now(), grace: time.Minute}, // fresh window
	}
	mountPod.Status.ContainerStatuses[0].RestartCount = 6
	r.HandleMountDaemonEvent(context.Background(), mountPod)
	if len(ev.attempts) != 0 {
		t.Fatalf("cold-start window should suppress Path A, got %d attempts", len(ev.attempts))
	}
}

var _ = fake.NewClientBuilder
var _ types.UID
```

- [ ] **Step 2: Run tests (expect fail)**

Run: `go test ./pkg/recycler/... -run TestReconciler -v`
Expected: FAIL (undefined `Reconciler.HandleMountDaemonEvent`).

- [ ] **Step 3: Implement reconciler.go**

Create `drivers/seaweedfs-csi-driver/pkg/recycler/reconciler.go`:
```go
package recycler

import (
	"context"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// Reconciler wires the two signal paths into a shared cycling pipeline.
// It is NOT a controller-runtime Reconciler{} — it's called directly from
// the Pod informer's event handler and from the Prober's Trigger hook. We
// use the reconcile-friendly shape (a single HandleX per signal source)
// without pretending to manage any custom resource.
type Reconciler struct {
	Client    client.Client
	NodeName  string
	Lookup    *PVLookup
	Cycler    *Cycler
	Baseline  *BaselineTracker
	ColdStart *ColdStartWindow
	Recorder  record.EventRecorder // may be nil in tests
	Log       logr.Logger
}

// HandleMountDaemonEvent is invoked by the Pod informer whenever a
// seaweedfs-mount pod on this node transitions. It detects restart events
// against the Baseline and, if triggered and not cold-start-suppressed,
// cycles all consumer candidates on the node.
func (r *Reconciler) HandleMountDaemonEvent(ctx context.Context, mountPod *corev1.Pod) {
	logger := r.logger(ctx)

	// Find the relevant container's RestartCount.
	var restartCount int32
	for _, cs := range mountPod.Status.ContainerStatuses {
		if cs.Name == "seaweedfs-mount" {
			restartCount = cs.RestartCount
			break
		}
	}

	triggered := r.Baseline.ObserveRestart(mountPod.UID, restartCount)
	if !triggered {
		return
	}

	if r.ColdStart.Suppressed(time.Now()) {
		ColdStartSuppressedTotal.Inc()
		logger.Info("cold-start window suppressing Path A", "mountPod", mountPod.Name, "restartCount", restartCount)
		return
	}

	TriggersTotal.WithLabelValues("event").Inc()
	logger.Info("mount daemon restart detected, enumerating candidates",
		"mountPod", mountPod.Name, "restartCount", restartCount, "node", r.NodeName)

	candidates, err := r.Lookup.ListCandidates(ctx)
	if err != nil {
		logger.Error(err, "ListCandidates failed")
		return
	}
	if len(candidates) == 0 {
		logger.Info("no candidates to cycle")
		return
	}
	if r.Recorder != nil {
		r.Recorder.Eventf(mountPod, corev1.EventTypeNormal, "RecycleTriggered",
			"restart detected; cycling %d consumer pod(s) on node %s", len(candidates), r.NodeName)
	}
	r.Cycler.CycleBatch(ctx, candidates)
}

// HandleProbeFailure is invoked by the Prober for each unhealthy mountpoint.
// It resolves the mountpoint back to a single consumer pod UID and, if found,
// cycles that single pod. Not subject to the cold-start window — probe-driven
// remediation always runs.
func (r *Reconciler) HandleProbeFailure(ctx context.Context, mountpoint string) {
	logger := r.logger(ctx)
	TriggersTotal.WithLabelValues("probe").Inc()

	uid := ResolvePodUIDFromMountpoint(mountpoint)
	if uid == "" {
		logger.Info("could not resolve pod UID from mountpoint", "mountpoint", mountpoint)
		return
	}

	candidates, err := r.Lookup.ListCandidates(ctx)
	if err != nil {
		logger.Error(err, "ListCandidates failed")
		return
	}
	for i := range candidates {
		if string(candidates[i].UID) == uid {
			if r.Recorder != nil {
				r.Recorder.Eventf(&candidates[i], corev1.EventTypeWarning, "RecycledStaleMount",
					"FUSE mount %s failed probe, cycling", mountpoint)
			}
			if err := r.Cycler.CycleOne(ctx, &candidates[i]); err != nil {
				logger.Error(err, "CycleOne failed", "pod", candidates[i].Name)
			}
			return
		}
	}
	logger.Info("probe-failed mountpoint had no matching candidate pod", "mountpoint", mountpoint, "uid", uid)
}

func (r *Reconciler) logger(ctx context.Context) logr.Logger {
	if r.Log.GetSink() != nil {
		return r.Log
	}
	return log.FromContext(ctx)
}
```

- [ ] **Step 4: Run tests (expect pass)**

Run: `go test ./pkg/recycler/... -v`
Expected: all PASS. If the helper `pkUID` returns `types.UID` the `corev1.Pod` UID will be set; make sure `pod()` in `pvlookup_test.go` sets UID via `pkUID(name)` consistently.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/recycler/reconciler.go drivers/seaweedfs-csi-driver/pkg/recycler/reconciler_test.go
git commit -m "feat(recycler): reconciler wires baseline, cold-start, cycler"
```

---

## Task 7: main.go — manager wiring

**Files:**
- Create: `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/main.go`

- [ ] **Step 1: Write main.go**

Create `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/main.go`:
```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/recycler"
)

const (
	driverName          = "seaweedfs-csi-driver"
	coldStartGrace      = 60 * time.Second
	probeInterval       = 30 * time.Second
	statTimeout         = 2 * time.Second
	stagger             = 5 * time.Second
	debounceTTL         = 120 * time.Second
	evictionRetry       = 5 * time.Second
	evictionDeadline    = 30 * time.Second
)

func main() {
	var (
		metricsAddr string
		probeAddr   string
		procRoot    string
		statPath    string
	)
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":9090", "Prometheus metrics bind address")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":9808", "Health probe bind address")
	flag.StringVar(&procRoot, "proc-root", "/host/proc", "Path to the host's /proc inside the container")
	flag.StringVar(&statPath, "stat-path", "/usr/bin/stat", "Path to the stat(1) binary")
	opts := zap.Options{Development: false}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	logger := ctrllog.Log.WithName("recycler")

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		logger.Error(fmt.Errorf("NODE_NAME env var is required"), "startup")
		os.Exit(1)
	}

	cfg, err := ctrl.GetConfig()
	if err != nil {
		logger.Error(err, "failed to get kubeconfig")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(cfg, manager.Options{
		LeaderElection:         false,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&corev1.Pod{}: {
					Field: fieldsByNode(nodeName),
				},
			},
		},
	})
	if err != nil {
		logger.Error(err, "manager init failed")
		os.Exit(1)
	}
	if err := mgr.AddHealthzCheck("ping", healthz.Ping); err != nil {
		logger.Error(err, "add healthz")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("ping", healthz.Ping); err != nil {
		logger.Error(err, "add readyz")
		os.Exit(1)
	}

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		logger.Error(err, "clientset init failed")
		os.Exit(1)
	}

	broadcaster := record.NewBroadcaster()
	broadcaster.StartRecordingToSink(&typedEventSink{Client: clientset})
	recorder := broadcaster.NewRecorder(mgr.GetScheme(), corev1.EventSource{Component: "seaweedfs-consumer-recycler"})

	reconciler := &recycler.Reconciler{
		Client:   mgr.GetClient(),
		NodeName: nodeName,
		Lookup: &recycler.PVLookup{
			Client:   mgr.GetClient(),
			NodeName: nodeName,
			Driver:   driverName,
		},
		Cycler: &recycler.Cycler{
			Evictor:          &recycler.KubeEvictor{Clientset: clientset},
			Debounce:         recycler.NewDebouncer(debounceTTL),
			Stagger:          stagger,
			EvictionRetry:    evictionRetry,
			EvictionDeadline: evictionDeadline,
		},
		Baseline:  recycler.NewBaselineTracker(),
		ColdStart: recycler.NewColdStartWindow(coldStartGrace),
		Recorder:  recorder,
		Log:       logger,
	}

	// Path A: Pod informer hook.
	if err := setupMountDaemonWatch(mgr, nodeName, reconciler); err != nil {
		logger.Error(err, "watch setup failed")
		os.Exit(1)
	}

	// Path B: prober goroutine.
	prober := &recycler.Prober{
		ProcRoot:    procRoot,
		StatPath:    statPath,
		StatTimeout: statTimeout,
		Interval:    probeInterval,
		Trigger: func(ctx context.Context, mp string) {
			reconciler.HandleProbeFailure(ctx, mp)
		},
	}
	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		prober.Run(ctx)
		return nil
	})); err != nil {
		logger.Error(err, "add prober runnable")
		os.Exit(1)
	}

	logger.Info("starting recycler", "node", nodeName, "coldStartGrace", coldStartGrace, "probeInterval", probeInterval)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "manager exited")
		os.Exit(1)
	}
}
```

- [ ] **Step 2: Write the informer wiring + fields selector helpers**

Create `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/watch.go`:
```go
package main

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/record"
	typedcorev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/recycler"
)

func fieldsByNode(nodeName string) fields.Selector {
	return fields.OneTermEqualSelector("spec.nodeName", nodeName)
}

// setupMountDaemonWatch registers a controller-runtime controller that
// reconciles seaweedfs-mount pods on this node. The "reconcile" is really a
// thin wrapper that fetches the pod and hands it to r.HandleMountDaemonEvent.
func setupMountDaemonWatch(mgr ctrl.Manager, nodeName string, r *recycler.Reconciler) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("seaweedfs-mount-watcher").
		For(&corev1.Pod{}, builder.WithPredicates(predicate.NewPredicateFuncs(func(obj client.Object) bool {
			pod, ok := obj.(*corev1.Pod)
			if !ok {
				return false
			}
			return pod.Spec.NodeName == nodeName && pod.Labels["component"] == "seaweedfs-mount"
		}))).
		WithEventFilter(predicate.Funcs{
			CreateFunc: func(e event.CreateEvent) bool { return true },
			UpdateFunc: func(e event.UpdateEvent) bool { return true },
			DeleteFunc: func(e event.DeleteEvent) bool { return false }, // handled by DeleteFunc below via custom handler if needed
		}).
		WatchesRawSource(nil). // no-op placeholder so the builder doesn't cry
		Complete(reconcile.Func(func(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
			var pod corev1.Pod
			if err := mgr.GetClient().Get(ctx, req.NamespacedName, &pod); err != nil {
				return reconcile.Result{}, client.IgnoreNotFound(err)
			}
			r.HandleMountDaemonEvent(ctx, &pod)
			return reconcile.Result{}, nil
		}))
}

// typedEventSink adapts clientset events to record.EventSink (used by
// record.Broadcaster.StartRecordingToSink).
type typedEventSink struct {
	Client interface {
		CoreV1() typedcorev1.CoreV1Interface
	}
}

func (s *typedEventSink) Create(event *corev1.Event) (*corev1.Event, error) {
	return s.Client.CoreV1().Events(event.Namespace).Create(context.TODO(), event, metaCreateOpts())
}
func (s *typedEventSink) Update(event *corev1.Event) (*corev1.Event, error) {
	return s.Client.CoreV1().Events(event.Namespace).Update(context.TODO(), event, metaUpdateOpts())
}
func (s *typedEventSink) Patch(event *corev1.Event, data []byte) (*corev1.Event, error) {
	return s.Client.CoreV1().Events(event.Namespace).Patch(context.TODO(), event.Name, k8sTypesStrategic(), data, metaPatchOpts())
}

// These wrappers keep the main.go imports tiny; real impl uses metav1 helpers.
var _ = rest.Config{}
var _ = record.NewBroadcaster
var _ = handler.EnqueueRequestForObject{}
```

**Note:** The wrapper helpers `metaCreateOpts`, `metaUpdateOpts`, `metaPatchOpts`, `k8sTypesStrategic` are small stubs — the real implementation should use `metav1.CreateOptions{}`, etc. Add a third file `events.go` next to `watch.go`:

```go
package main

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func metaCreateOpts() metav1.CreateOptions { return metav1.CreateOptions{} }
func metaUpdateOpts() metav1.UpdateOptions { return metav1.UpdateOptions{} }
func metaPatchOpts() metav1.PatchOptions   { return metav1.PatchOptions{} }
func k8sTypesStrategic() types.PatchType   { return types.StrategicMergePatchType }
```

- [ ] **Step 3: Build and verify**

Run (from `drivers/seaweedfs-csi-driver/`):
```bash
CGO_ENABLED=0 GOOS=linux go build -o /tmp/seaweedfs-consumer-recycler ./cmd/seaweedfs-consumer-recycler/
```

Expected: exit 0, binary created. If there are compilation errors, fix imports and builder semantics — controller-runtime's builder API changed subtly across versions, and the `WatchesRawSource(nil)` line above may need removal if it errors.

- [ ] **Step 4: Run all recycler tests one more time**

Run: `go test ./pkg/recycler/... -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/
git commit -m "feat(recycler): main.go wires manager, informer, prober"
```

---

## Task 8: Dockerfile + Makefile targets

**Files:**
- Create: `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/Dockerfile`
- Modify: `drivers/seaweedfs-csi-driver/Makefile`

- [ ] **Step 1: Create Dockerfile**

Create `drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/Dockerfile`:
```dockerfile
FROM golang:1.25-alpine AS builder

RUN apk add git g++

WORKDIR /go/src/github.com/seaweedfs/seaweedfs-csi-driver
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /seaweedfs-consumer-recycler ./cmd/seaweedfs-consumer-recycler/ \
    && go clean -cache -modcache

FROM alpine AS final
RUN apk add --no-cache coreutils
LABEL author="Ben Martin"
COPY --from=builder /seaweedfs-consumer-recycler /

RUN chmod +x /seaweedfs-consumer-recycler
ENTRYPOINT ["/seaweedfs-consumer-recycler"]
```

**Note:** `coreutils` provides `stat(1)` — required for the prober's subprocess calls.

- [ ] **Step 2: Add Makefile targets**

Modify `drivers/seaweedfs-csi-driver/Makefile`. Find the existing `build: $(DRIVER_BINARY) $(MOUNT_BINARY)` line and replace it, and add new rules at the bottom.

Add at the top variables section (after existing variable lines):
```makefile
RECYCLER_IMAGE_NAME ?= seaweedfs-consumer-recycler
RECYCLER_BINARY := $(OUTPUT_DIR)/seaweedfs-consumer-recycler
RECYCLER_IMAGE_TAG := $(REGISTRY_NAME)/$(RECYCLER_IMAGE_NAME):$(VERSION)
```

Change the `build:` line:
```makefile
build: $(DRIVER_BINARY) $(MOUNT_BINARY) $(RECYCLER_BINARY)
```

Add a new binary rule:
```makefile
$(RECYCLER_BINARY): | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-consumer-recycler/
```

Add to the `container:` target:
```makefile
container: container-csi container-mount container-recycler
```

Add the new container build:
```makefile
container-recycler:
	docker build -t $(RECYCLER_IMAGE_TAG) -f cmd/seaweedfs-consumer-recycler/Dockerfile .
```

Add to `push:` target:
```makefile
push: push-csi push-mount push-recycler
```

Add:
```makefile
push-recycler: container-recycler
	docker push $(RECYCLER_IMAGE_TAG)
```

- [ ] **Step 3: Local build verification**

Run (from `drivers/seaweedfs-csi-driver/`):
```bash
make build
```

Expected: `_output/seaweedfs-consumer-recycler` binary exists alongside the other two.

- [ ] **Step 4: Commit**

```bash
git add drivers/seaweedfs-csi-driver/cmd/seaweedfs-consumer-recycler/Dockerfile drivers/seaweedfs-csi-driver/Makefile
git commit -m "feat(recycler): Dockerfile + Makefile targets"
```

---

## Task 9: Terraform RBAC + DaemonSet + Service

**Files:**
- Create: `modules-k8s/seaweedfs/consumer-recycler.tf`
- Modify: `modules-k8s/seaweedfs/variables.tf`

- [ ] **Step 1: Add variable**

Modify `modules-k8s/seaweedfs/variables.tf`. After the `csi_mount_image_tag` block, add:
```hcl
variable "consumer_recycler_image_tag" {
  description = "SeaweedFS consumer recycler image tag"
  type        = string
  default     = "v0.1.0"
}
```

- [ ] **Step 2: Create consumer-recycler.tf**

Create `modules-k8s/seaweedfs/consumer-recycler.tf`:
```hcl
# -----------------------------------------------------------------------------
# SeaweedFS Consumer Recycler — DaemonSet
#
# Per-node reconciler that cycles consumer pods when seaweedfs-mount restarts
# or a FUSE mount goes bad. See:
#   docs/superpowers/specs/2026-04-08-seaweedfs-consumer-recycler-design.md
# -----------------------------------------------------------------------------

resource "kubernetes_service_account" "consumer_recycler" {
  metadata {
    name      = "seaweedfs-consumer-recycler"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "consumer-recycler" })
  }
}

resource "kubernetes_cluster_role" "consumer_recycler" {
  metadata {
    name   = "seaweedfs-consumer-recycler"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "consumer_recycler" {
  metadata {
    name   = "seaweedfs-consumer-recycler"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.consumer_recycler.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.consumer_recycler.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_daemon_set_v1" "consumer_recycler" {
  metadata {
    name      = "seaweedfs-consumer-recycler"
    namespace = var.namespace
    labels = merge(local.labels, {
      component                    = "consumer-recycler"
      "app.kubernetes.io/name"     = "seaweedfs-consumer-recycler"
    })
  }

  spec {
    selector {
      match_labels = {
        app                      = local.app_name
        "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
      }
    }

    template {
      metadata {
        labels = merge(local.labels, {
          "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
          component                = "consumer-recycler"
        })
      }

      spec {
        service_account_name = kubernetes_service_account.consumer_recycler.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name              = "recycler"
          image             = "registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:${var.consumer_recycler_image_tag}"
          image_pull_policy = "IfNotPresent"

          args = [
            "--metrics-bind-address=:9090",
            "--health-probe-bind-address=:9808",
            "--proc-root=/host/proc",
            "--stat-path=/usr/bin/stat",
          ]

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 9090
          }

          port {
            name           = "healthz"
            container_port = 9808
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "healthz"
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = "healthz"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "host-proc"
            mount_path = "/host/proc"
            read_only  = true
          }

          volume_mount {
            name       = "kubelet-pods"
            mount_path = "/var/lib/kubelet/pods"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "host-proc"
          host_path {
            path = "/proc"
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
      }
    }
  }
}

resource "kubernetes_service" "consumer_recycler_metrics" {
  metadata {
    name      = "seaweedfs-consumer-recycler-metrics"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "consumer-recycler" })
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9090"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    cluster_ip = "None" # headless — per-pod scraping
    selector = {
      app                      = local.app_name
      "app.kubernetes.io/name" = "seaweedfs-consumer-recycler"
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = "metrics"
    }
  }
}
```

- [ ] **Step 3: Format and validate**

Run:
```bash
set -a && source .env && set +a
terraform fmt modules-k8s/seaweedfs/consumer-recycler.tf modules-k8s/seaweedfs/variables.tf
terraform validate
```

Expected: `terraform validate` reports "The configuration is valid." `terraform fmt` is a no-op or reformats whitespace only.

- [ ] **Step 4: Commit**

```bash
git add modules-k8s/seaweedfs/consumer-recycler.tf modules-k8s/seaweedfs/variables.tf
git commit -m "feat(seaweedfs): terraform for consumer-recycler DaemonSet + RBAC"
```

---

## Task 10: CI pipeline stage for drivers/

**Files:**
- Modify: `.gitlab-ci.yml`

- [ ] **Step 1: Read current pipeline**

Run: `cat .gitlab-ci.yml` (or use Read tool) to identify where the terraform stages are defined.

- [ ] **Step 2: Add drivers-build stage**

Add a new stage before `validate` or as the first stage, plus a job definition. Exact shape depends on the existing pipeline — the key properties:
- `stage: drivers-build` (or similar)
- `image: golang:1.25-alpine`
- `rules: - changes: [ drivers/**/* ]`
- Script runs `go test ./...` then `go build`, then pushes to the internal registry using `buildah` or `kaniko` (whichever the existing registry-bypass path uses; see `modules-k8s/gitlab-runner/main.tf` registries.conf).
- Output image tag: `registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:$CI_COMMIT_SHORT_SHA`

Example job (adjust to match existing style):
```yaml
drivers-build:
  stage: build
  image: golang:1.25-alpine
  before_script:
    - apk add --no-cache git make docker-cli
  rules:
    - changes:
        - drivers/**/*
      if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - cd drivers/seaweedfs-csi-driver
    - go test ./...
    - make container-recycler VERSION=$CI_COMMIT_SHORT_SHA REGISTRY_NAME=registry.brmartin.co.uk/ben
    - make push-recycler VERSION=$CI_COMMIT_SHORT_SHA REGISTRY_NAME=registry.brmartin.co.uk/ben
```

**Note:** This may need adaptation — the existing repo pushes container images through the GitLab runner's buildah-via-insecure-registries path documented in AGENTS.md. If the repo doesn't currently build any container images in CI (check `.gitlab-ci.yml`), skip this task for now and note that the first deploy will be a manual `make container-recycler && k3s ctr images import`. Record in the task's commit message that CI integration is deferred.

- [ ] **Step 3: Validate pipeline locally (best-effort)**

Run: `glab ci lint` (if installed) to sanity-check the YAML.
Expected: no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci(drivers): build + push recycler image on drivers/ changes"
```

---

## Task 11: First build and sideload

**Files:** none

- [ ] **Step 1: Local container build**

Run (from `drivers/seaweedfs-csi-driver/`):
```bash
make container-recycler VERSION=v0.1.0 REGISTRY_NAME=registry.brmartin.co.uk/ben
```

Expected: Docker builds the image successfully.

- [ ] **Step 2: Save and sideload to each node**

Per AGENTS.md + memory notes: the internal registry `registry.brmartin.co.uk/ben` is backed by the CSI itself, so during first deploy (before the recycler is running) push may not work. Sideload via `k3s ctr images import` instead.

```bash
docker save registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:v0.1.0 -o /tmp/recycler.tar
for ip in 192.168.1.5 192.168.1.6 192.168.1.7; do
  /usr/bin/scp /tmp/recycler.tar ben@${ip}:/tmp/recycler.tar
  /usr/bin/ssh ben@${ip} "sudo k3s ctr -n k8s.io images import /tmp/recycler.tar && rm /tmp/recycler.tar"
done
rm /tmp/recycler.tar
```

Expected: each node reports `unpacking registry.brmartin.co.uk/ben/seaweedfs-consumer-recycler:v0.1.0 ...done`.

- [ ] **Step 3: Verify images on each node**

```bash
for ip in 192.168.1.5 192.168.1.6 192.168.1.7; do
  echo "=== $ip ==="
  /usr/bin/ssh ben@${ip} "sudo k3s ctr -n k8s.io images ls | grep consumer-recycler"
done
```

Expected: all three nodes list the image.

---

## Task 12: Targeted terraform apply + observe

**Files:** none (deploy + watch)

- [ ] **Step 1: Plan the change**

Run:
```bash
set -a && source .env && set +a
terraform plan -target=module.seaweedfs_storage.kubernetes_service_account.consumer_recycler \
               -target=module.seaweedfs_storage.kubernetes_cluster_role.consumer_recycler \
               -target=module.seaweedfs_storage.kubernetes_cluster_role_binding.consumer_recycler \
               -target=module.seaweedfs_storage.kubernetes_daemon_set_v1.consumer_recycler \
               -target=module.seaweedfs_storage.kubernetes_service.consumer_recycler_metrics \
               -out=tfplan
```

Expected: plan shows 5 resources to create. Replace `seaweedfs_storage` with the actual module name (check `kubernetes.tf` in the repo root).

- [ ] **Step 2: Apply**

Run: `terraform apply tfplan`
Expected: 5 resources created.

- [ ] **Step 3: Observe pod startup**

```bash
kubectl get ds -n default seaweedfs-consumer-recycler -w
```

Expected within 60s: `DESIRED=3 CURRENT=3 READY=3`.

- [ ] **Step 4: Check logs for cold-start announcement**

```bash
kubectl logs -n default -l app.kubernetes.io/name=seaweedfs-consumer-recycler --tail=50
```

Expected: each recycler pod logs `starting recycler ... coldStartGrace=1m0s probeInterval=30s` and a subsequent probe sweep with no failures.

- [ ] **Step 5: Verify metrics endpoint**

```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=seaweedfs-consumer-recycler -o name | head -1)
kubectl exec -n default $POD -- wget -qO- http://localhost:9090/metrics | grep seaweedfs_recycler
```

Expected: output includes `seaweedfs_recycler_probe_duration_seconds_*` and counter series.

---

## Task 13: Acceptance test per node

**Files:** none

- [ ] **Step 1: Baseline check on nyx**

```bash
kubectl get pods -n default --field-selector=spec.nodeName=nyx -o wide | head -20
```

Record the list of consumer pods with `seaweedfs` PVCs. Expected: all Running.

- [ ] **Step 2: Delete seaweedfs-mount on nyx**

```bash
kubectl delete pod -n default -l component=seaweedfs-mount --field-selector=spec.nodeName=nyx
```

Expected: new pod comes up within 30-60s.

- [ ] **Step 3: Watch recycler logs on nyx**

```bash
kubectl logs -n default -l app.kubernetes.io/name=seaweedfs-consumer-recycler --tail=100 -f \
  | grep -E "nyx|mount-daemon|RecycleTriggered|RecycledStaleMount"
```

Expected: within 60s of the new mount pod becoming Ready, logs show `mount daemon restart detected ... candidates=N` and per-pod cycling events.

- [ ] **Step 4: Verify consumer recovery**

```bash
kubectl get pods -n default --field-selector=spec.nodeName=nyx -o wide | head -20
```

Expected: all former seaweedfs consumers have new pod UIDs, Running with healthy FUSE mounts. No manual `kubectl delete pod` required.

- [ ] **Step 5: Repeat for heracles and hestia**

Same steps 1–4 for each node.

- [ ] **Step 6: Verify success criterion**

The Gap #2 success criterion from the planning notes is: `seaweedfs-mount` pod restart no longer requires a human running `kubectl delete pod`. If steps 2–4 succeeded without operator intervention on all three nodes, this work is complete.

---

## Task 14: Full terraform apply + documentation sync

**Files:**
- Modify: `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`

- [ ] **Step 1: Full apply**

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

Expected: no changes (targeted apply already brought everything up) or minor drift only.

- [ ] **Step 2: Update planning notes**

Edit `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`, mark Gap #2 as **COMPLETE** with a reference to the spec and this plan. Add a one-line note at the top of the file stating "Gap #2 shipped <date>".

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md
git commit -m "docs(seaweedfs): mark Gap #2 (consumer-recycler) as shipped"
```

- [ ] **Step 4: Update memory**

Update `~/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/project_seaweedfs_reconcile_propagation_2026_04_08.md` — append a "Follow-up: consumer recycler shipped" section noting that mount-daemon restart is now self-healing, and remove the "requires consumer pod cycling" warning.

---

## Self-Review Notes (completed during plan authoring)

**Spec coverage:** Every section of the design spec maps to at least one task. Path A → Tasks 3, 6, 7. Path B → Tasks 5, 7. Cycler + fallback → Task 4. Startup safety → Tasks 3, 6. RBAC/deployment → Task 9. CI → Task 10. Acceptance → Task 13.

**Known caveats requiring engineer judgment:**
1. **controller-runtime builder API:** The `WatchesRawSource(nil)` placeholder in `watch.go` (Task 7, Step 2) may not compile against v0.20.4. If so, remove that line — it was only included to demonstrate structure. The `For(...)` + predicate chain is sufficient.
2. **Event sink wiring:** `record.Broadcaster.StartRecordingToSink` requires an implementation of `record.EventSink`. The `typedEventSink` struct in the plan is illustrative; the engineer may prefer the canonical `k8s.io/client-go/tools/record/EventSink` with `record.Broadcaster.StartStructuredLogging()` + `StartRecordingToSink(&typedcorev1.EventSinkImpl{Interface: clientset.CoreV1().Events("")})` instead. Both are valid; the latter is more idiomatic.
3. **CI integration (Task 10)**: path-filtered Go builds are new territory for this pipeline. If the pipeline doesn't already build container images, deferring CI to a follow-up commit is acceptable — the first deploy via `make container-recycler` + sideload works regardless.
4. **Image tag bootstrapping (Task 9, Task 11)**: The default `consumer_recycler_image_tag = "v0.1.0"` matches the VERSION used in the manual sideload. Subsequent bumps go through CI.

No placeholders (`TBD`, `TODO`) remain in the plan. Types and method signatures are consistent across tasks: `Cycler`, `Evictor`, `Reconciler`, `PVLookup`, `Prober`, `BaselineTracker`, `ColdStartWindow`, `Debouncer`.
