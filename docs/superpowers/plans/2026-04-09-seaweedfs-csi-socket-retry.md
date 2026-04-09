# SeaweedFS CSI Socket Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bounded retry loop to `pkg/mountmanager.Client.doPost()` that recovers from transient transport failures (ENOENT/ECONNREFUSED) on the unix socket between csi-node and seaweedfs-mount, eliminating minute-scale kubelet backoff on node reboot. Ship as monorepo release `v0.1.2`.

**Architecture:** Retry lives at the `doPost()` layer so all RPC calls benefit. Polling uses `k8s.io/apimachinery/pkg/util/wait.PollUntilContextTimeout` (already in the dep tree). Errors are classified by a pure function in `client_retry.go`. Observability via Prometheus counters/histogram registered to `controller-runtime/pkg/metrics.Registry` (mirrors the recycler), a new `/metrics` HTTP server in csi-node `main.go`, and graceful-degrade k8s Event emission on retry exhaustion. Context flows from the gRPC `NodePublishVolume` request through `Mounter.Mount` → `client.Mount` → `doPost`.

**Tech Stack:** Go (existing module), `k8s.io/apimachinery/pkg/util/wait`, `prometheus/client_golang`, `controller-runtime/pkg/metrics`, `client-go` `EventsV1`. Terraform `kubernetes` provider in `modules-k8s/seaweedfs/`. Image build via existing `drivers/seaweedfs-csi-driver/Makefile` (`VERSION=v0.1.2`). Sideload to all three nodes (registry is backed by SeaweedFS — chicken-egg).

**Spec reference:** `docs/superpowers/specs/2026-04-09-seaweedfs-csi-socket-retry-design.md`. Read this first — it contains the full "why". This plan is the "how".

**Key memory pointers (read before starting):**
- `memory/project_seaweedfs_driver_monorepo_layout.md` — driver lives in-tree
- `memory/project_seaweedfs_monorepo_versioning.md` — unified v0.x versioning
- `memory/feedback_always_sideload_seaweedfs_images.md` — never push driver images to registry
- `memory/feedback_reputable_libraries.md` — use stdlib/established deps, not hand-rolled

---

## Task 1: Setup — branch and baseline

**Files:**
- None modified

- [ ] **Step 1: Create feature branch**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
git checkout -b feat/csi-socket-retry
```

- [ ] **Step 2: Confirm baseline tests pass**

```bash
cd drivers/seaweedfs-csi-driver
go test ./pkg/mountmanager/... -count=1
```

Expected: `ok` (or `?` no test files) for the package. If failures appear, stop and investigate before continuing — you need a green baseline.

- [ ] **Step 3: Confirm `wait` package is importable (no go.mod change needed)**

```bash
go list -m k8s.io/apimachinery
```

Expected: `k8s.io/apimachinery v0.32.x` printed. If this fails, the plan needs a `go get` step — flag it.

---

## Task 2: Retry classifier (TDD)

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry.go`
- Create: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go`

- [ ] **Step 1: Write the failing classifier table test**

Create `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go`:

```go
package mountmanager

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"syscall"
	"testing"
)

func TestShouldRetryDial(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"raw ENOENT", syscall.ENOENT, true},
		{"raw ECONNREFUSED", syscall.ECONNREFUSED, true},
		{"net.OpError dial ENOENT", &net.OpError{Op: "dial", Err: syscall.ENOENT}, true},
		{"net.OpError read EOF", &net.OpError{Op: "read", Err: io.EOF}, false},
		{"url.Error wrapping dial", &url.Error{Op: "Post", URL: "http://unix/mount", Err: &net.OpError{Op: "dial", Err: syscall.ENOENT}}, true},
		{"plain http 500-style error", fmt.Errorf("500 Internal Server Error"), false},
		{"context.Canceled", context.Canceled, false},
		{"context.DeadlineExceeded", context.DeadlineExceeded, false},
		{"wrapped ENOENT via fmt.Errorf %w", fmt.Errorf("dial: %w", syscall.ENOENT), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := shouldRetryDial(c.err)
			if got != c.want {
				t.Errorf("shouldRetryDial(%v) = %v, want %v", c.err, got, c.want)
			}
		})
	}
	// Sanity: errors.Is unwrapping should work
	wrapped := fmt.Errorf("outer: %w", &net.OpError{Op: "dial", Err: syscall.ECONNREFUSED})
	if !errors.Is(wrapped, syscall.ECONNREFUSED) {
		t.Skip("errors.Is doesn't unwrap as expected — test fixture is wrong")
	}
}
```

- [ ] **Step 2: Verify the test fails (function does not exist)**

```bash
cd drivers/seaweedfs-csi-driver
go test ./pkg/mountmanager/ -run TestShouldRetryDial
```

Expected: compile error `undefined: shouldRetryDial`.

- [ ] **Step 3: Write the classifier implementation**

Create `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry.go`:

```go
package mountmanager

import (
	"errors"
	"net"
	"net/url"
	"syscall"
	"time"
)

// Default retry budget for Client.doPost dial failures.
// On a node reboot, seaweedfs-mount typically becomes reachable within
// single-digit seconds. The 30s budget gives generous headroom while
// staying well below kubelet's per-RPC deadline.
const (
	dialRetryBudget   = 30 * time.Second
	dialRetryInterval = 1 * time.Second
)

// clientRetryConfig is injected into Client so unit tests can use a much
// shorter budget without changing production defaults.
type clientRetryConfig struct {
	budget   time.Duration
	interval time.Duration
}

func defaultRetryConfig() clientRetryConfig {
	return clientRetryConfig{budget: dialRetryBudget, interval: dialRetryInterval}
}

// shouldRetryDial returns true for transport-level dial failures that
// indicate the mount service is not yet reachable. It deliberately does
// NOT match HTTP status errors (4xx/5xx) or context cancellations — those
// must propagate immediately so real bugs and intentional cancellation
// are not masked by retry noise.
func shouldRetryDial(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, syscall.ENOENT) {
		return true
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return true
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) && opErr.Op == "dial" {
		return true
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return shouldRetryDial(urlErr.Err)
	}
	return false
}
```

- [ ] **Step 4: Verify the test passes**

```bash
go test ./pkg/mountmanager/ -run TestShouldRetryDial -v
```

Expected: all subtests PASS.

- [ ] **Step 5: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry.go drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go
git commit -m "feat(csi/retry): classifier for transport-level dial failures"
```

---

## Task 3: Metrics package

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_metrics.go`

- [ ] **Step 1: Write the metrics file**

Create `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_metrics.go`:

```go
package mountmanager

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// Metric naming follows the pkg/recycler/metrics.go convention so all
// monorepo components share one prefix and one registry.
var (
	dialRetriesTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_csi_dial_retries_total",
			Help: "Mount-service RPC dial retry outcomes.",
		},
		[]string{"outcome"}, // "recovered" | "exhausted"
	)
	dialRetryDurationSeconds = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "seaweedfs_csi_dial_retry_duration_seconds",
			Help:    "Wall-clock duration of mount-service RPC dial retry windows.",
			Buckets: prometheus.DefBuckets,
		},
	)
)

func init() {
	metrics.Registry.MustRegister(dialRetriesTotal, dialRetryDurationSeconds)
}
```

- [ ] **Step 2: Verify the package compiles**

```bash
cd drivers/seaweedfs-csi-driver
go build ./pkg/mountmanager/...
```

Expected: no output (success).

- [ ] **Step 3: Verify metric names parse via a smoke test**

```bash
go test ./pkg/mountmanager/ -count=1
```

Expected: existing tests PASS, no panic from `MustRegister` (which would fire on a duplicate metric name).

- [ ] **Step 4: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/mountmanager/client_metrics.go
git commit -m "feat(csi/retry): prometheus counters and histogram for dial retries"
```

---

## Task 4: Failing tests for doPost retry loop

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go`

- [ ] **Step 1: Add httptest-based retry tests**

Append to `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go`:

```go
import (
	// ...existing imports above...
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

// newUnixHTTPServer starts an http.Server bound to a unix socket at the
// returned path. The caller is responsible for calling close() to stop
// the server and remove the socket.
func newUnixHTTPServer(t *testing.T, handler http.Handler) (sockPath string, close func()) {
	t.Helper()
	dir := t.TempDir()
	sockPath = filepath.Join(dir, "mount.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	srv := &http.Server{Handler: handler}
	go srv.Serve(ln) //nolint:errcheck
	return sockPath, func() {
		_ = srv.Close()
		_ = os.Remove(sockPath)
	}
}

// newClientForTest builds a Client wired to a unix-domain endpoint with
// a fast retry config so subtests run in <500ms.
func newClientForTest(t *testing.T, sockPath string) *Client {
	t.Helper()
	c, err := NewClient("unix://" + sockPath)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	c.retry = clientRetryConfig{budget: 100 * time.Millisecond, interval: 10 * time.Millisecond}
	return c
}

func TestDoPost_HappyPath(t *testing.T) {
	resetCounters(t)
	sockPath, closeSrv := newUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer closeSrv()

	c := newClientForTest(t, sockPath)
	var resp MountResponse
	if err := c.doPost(context.Background(), "/mount", &MountRequest{}, &resp); err != nil {
		t.Fatalf("doPost: %v", err)
	}
	if got := testutil.ToFloat64(dialRetriesTotal.WithLabelValues("recovered")); got != 0 {
		t.Errorf("recovered counter = %v, want 0 on first-attempt success", got)
	}
}

func TestDoPost_RecoversAfterDelay(t *testing.T) {
	resetCounters(t)
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "mount.sock")

	// Start a goroutine that creates the listener after 30ms.
	var srv *http.Server
	var srvWG sync.WaitGroup
	srvWG.Add(1)
	go func() {
		defer srvWG.Done()
		time.Sleep(30 * time.Millisecond)
		ln, err := net.Listen("unix", sockPath)
		if err != nil {
			t.Errorf("delayed listen: %v", err)
			return
		}
		srv = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		})}
		_ = srv.Serve(ln)
	}()
	defer func() {
		srvWG.Wait()
		if srv != nil {
			_ = srv.Close()
		}
		_ = os.Remove(sockPath)
	}()

	c := newClientForTest(t, sockPath)
	var resp MountResponse
	if err := c.doPost(context.Background(), "/mount", &MountRequest{}, &resp); err != nil {
		t.Fatalf("doPost: %v", err)
	}
	if got := testutil.ToFloat64(dialRetriesTotal.WithLabelValues("recovered")); got != 1 {
		t.Errorf("recovered counter = %v, want 1", got)
	}
}

func TestDoPost_BudgetExhausted(t *testing.T) {
	resetCounters(t)
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "missing.sock")

	c := newClientForTest(t, sockPath)
	var resp MountResponse
	err := c.doPost(context.Background(), "/mount", &MountRequest{}, &resp)
	if err == nil {
		t.Fatal("doPost: expected error, got nil")
	}
	if !strings.Contains(err.Error(), "unreachable") {
		t.Errorf("error = %q, want substring 'unreachable'", err.Error())
	}
	if got := testutil.ToFloat64(dialRetriesTotal.WithLabelValues("exhausted")); got != 1 {
		t.Errorf("exhausted counter = %v, want 1", got)
	}
}

func TestDoPost_NonRetryable500(t *testing.T) {
	resetCounters(t)
	var calls atomic.Int64
	sockPath, closeSrv := newUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		http.Error(w, `{"error":"boom"}`, http.StatusInternalServerError)
	}))
	defer closeSrv()

	c := newClientForTest(t, sockPath)
	start := time.Now()
	var resp MountResponse
	err := c.doPost(context.Background(), "/mount", &MountRequest{}, &resp)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("doPost: expected error, got nil")
	}
	if elapsed > 50*time.Millisecond {
		t.Errorf("elapsed = %v, want <50ms (no retry should occur on 500)", elapsed)
	}
	if calls.Load() != 1 {
		t.Errorf("server saw %d calls, want 1 (no retry)", calls.Load())
	}
}

func TestDoPost_ContextCancelled(t *testing.T) {
	resetCounters(t)
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "missing.sock")

	c := newClientForTest(t, sockPath)
	c.retry.budget = 5 * time.Second // long budget to prove cancellation wins
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	start := time.Now()
	var resp MountResponse
	err := c.doPost(ctx, "/mount", &MountRequest{}, &resp)
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err = %v, want context.Canceled", err)
	}
	if elapsed > 200*time.Millisecond {
		t.Errorf("elapsed = %v, want <200ms (cancel should short-circuit)", elapsed)
	}
}

// resetCounters zeroes the package metrics so a fresh test starts from
// known state. Safe to call from any test — Reset() is provided by
// prometheus client_golang for CounterVec.
func resetCounters(t *testing.T) {
	t.Helper()
	dialRetriesTotal.Reset()
}
```

Add `"strings"` to the imports if it's not already there.

- [ ] **Step 2: Verify the new tests fail to compile (doPost has wrong signature)**

```bash
cd drivers/seaweedfs-csi-driver
go test ./pkg/mountmanager/ -run TestDoPost
```

Expected: compile error referencing `c.doPost` signature mismatch (current signature does not take `context.Context`) and `c.retry` undefined field.

This is correct — we will fix it in Task 5.

---

## Task 5: doPost retry loop implementation

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go`

- [ ] **Step 1: Add `retry` field to Client and update NewClient**

In `drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go`, replace the `Client` struct and `NewClient` function with:

```go
// Client talks to the mount service over a Unix domain socket.
type Client struct {
	httpClient *http.Client
	baseURL    string
	endpoint   string // raw endpoint string for log/metric labelling
	retry      clientRetryConfig
}

// NewClient builds a new Client for the given endpoint.
func NewClient(endpoint string) (*Client, error) {
	scheme, address, err := ParseEndpoint(endpoint)
	if err != nil {
		return nil, err
	}
	if scheme != "unix" {
		return nil, fmt.Errorf("unsupported endpoint scheme: %s", scheme)
	}

	dialer := &net.Dialer{}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", address)
		},
	}

	return &Client{
		httpClient: &http.Client{
			Timeout:   30 * time.Second,
			Transport: transport,
		},
		baseURL:  "http://unix",
		endpoint: endpoint,
		retry:    defaultRetryConfig(),
	}, nil
}
```

- [ ] **Step 2: Update Mount/Unmount to take context**

Replace the `Mount` and `Unmount` methods in `client.go`:

```go
// Mount mounts a volume using the mount service.
func (c *Client) Mount(ctx context.Context, req *MountRequest) (*MountResponse, error) {
	var resp MountResponse
	if err := c.doPost(ctx, "/mount", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

// Unmount unmounts a volume using the mount service.
func (c *Client) Unmount(ctx context.Context, req *UnmountRequest) (*UnmountResponse, error) {
	var resp UnmountResponse
	if err := c.doPost(ctx, "/unmount", req, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}
```

- [ ] **Step 3: Rewrite doPost with retry loop**

Replace the `doPost` function in `client.go`:

```go
func (c *Client) doPost(ctx context.Context, path string, payload any, out any) error {
	body := &bytes.Buffer{}
	if err := json.NewEncoder(body).Encode(payload); err != nil {
		return fmt.Errorf("encode request: %w", err)
	}
	bodyBytes := body.Bytes()

	var (
		warned    bool
		attempts  int
		startTime = time.Now()
		lastErr   error
	)

	pollErr := wait.PollUntilContextTimeout(ctx, c.retry.interval, c.retry.budget, true, func(ctx context.Context) (bool, error) {
		attempts++

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(bodyBytes))
		if err != nil {
			return false, fmt.Errorf("build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := c.httpClient.Do(req)
		if err != nil {
			if shouldRetryDial(err) {
				lastErr = err
				if !warned {
					glog.Warningf("mount service unreachable at %s, retrying (budget=%s): %v", c.endpoint, c.retry.budget, err)
					warned = true
				}
				return false, nil // keep polling
			}
			return false, err // non-retryable
		}
		defer resp.Body.Close()

		if resp.StatusCode >= 400 {
			var errResp ErrorResponse
			if err := json.NewDecoder(resp.Body).Decode(&errResp); err == nil && errResp.Error != "" {
				return false, errors.New(errResp.Error)
			}
			data, readErr := io.ReadAll(resp.Body)
			if readErr != nil {
				return false, fmt.Errorf("mount service error: %s (failed to read body: %v)", resp.Status, readErr)
			}
			return false, fmt.Errorf("mount service error: %s (%s)", resp.Status, string(data))
		}

		if out != nil {
			if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
				return false, fmt.Errorf("decode response: %w", err)
			}
		} else {
			_, _ = io.Copy(io.Discard, resp.Body)
		}
		return true, nil
	})

	elapsed := time.Since(startTime)

	if pollErr == nil {
		if warned {
			dialRetriesTotal.WithLabelValues("recovered").Inc()
			dialRetryDurationSeconds.Observe(elapsed.Seconds())
			glog.Infof("mount service reachable after %.1fs (%d attempts)", elapsed.Seconds(), attempts)
		}
		return nil
	}

	// Distinguish budget-exhaustion from a non-retryable error returned
	// from the poll function. wait.PollUntilContextTimeout returns
	// context.DeadlineExceeded on budget exhaustion (the inner ctx hits
	// its deadline) and the original err otherwise.
	if errors.Is(pollErr, context.DeadlineExceeded) && lastErr != nil {
		dialRetriesTotal.WithLabelValues("exhausted").Inc()
		dialRetryDurationSeconds.Observe(elapsed.Seconds())
		glog.Errorf("mount service at %s unreachable after %s, giving up; kubelet will retry", c.endpoint, elapsed)
		return fmt.Errorf("mount service at %s unreachable after %s: %w", c.endpoint, elapsed, lastErr)
	}

	if errors.Is(pollErr, context.Canceled) {
		return context.Canceled
	}
	return pollErr
}
```

- [ ] **Step 4: Add the new imports to client.go**

In the import block of `client.go`, add:

```go
"errors"
"time"

"github.com/seaweedfs/seaweedfs/weed/glog"
"k8s.io/apimachinery/pkg/util/wait"
```

(Keep the existing imports — `bytes`, `context`, `encoding/json`, `fmt`, `io`, `net`, `net/http`.)

- [ ] **Step 5: Run the doPost tests**

```bash
cd drivers/seaweedfs-csi-driver
go test ./pkg/mountmanager/ -run TestDoPost -v
```

Expected: all 5 subtests PASS in <2s total.

- [ ] **Step 6: Run the entire mountmanager package**

```bash
go test ./pkg/mountmanager/... -count=1
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go
git commit -m "feat(csi/retry): bounded retry loop in doPost on dial failures"
```

---

## Task 6: Thread context through Mounter and Volume

The `client.Mount`/`Unmount` now require a `context.Context`. Propagate it from `nodeserver.NodePublishVolume` (which already has a gRPC ctx) down through `stageNewVolume` → `Volume.Stage` → `Mounter.Mount`.

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go`
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/volume.go`
- Modify: `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go`

- [ ] **Step 1: Update Mounter and Unmounter interfaces in mounter.go**

In `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go`, replace the interface definitions and the `mountServiceMounter.Mount` / `mountServiceUnmounter.Unmount` methods with context-aware versions:

```go
type Unmounter interface {
	Unmount(ctx context.Context) error
}

type Mounter interface {
	Mount(ctx context.Context, target string) (Unmounter, error)
}
```

And update the method bodies to thread `ctx`:

```go
func (m *mountServiceMounter) Mount(ctx context.Context, target string) (Unmounter, error) {
	if target == "" {
		return nil, fmt.Errorf("target path is required")
	}

	filers := make([]string, len(m.driver.filers))
	for i, address := range m.driver.filers {
		filers[i] = string(address)
	}

	cacheDir := GetCacheDir(m.driver.CacheDir, m.volumeID)
	localSocket := GetLocalSocket(m.driver.volumeSocketDir, m.volumeID)

	args, err := m.buildMountArgs(target, cacheDir, localSocket, filers)
	if err != nil {
		return nil, err
	}

	req := &mountmanager.MountRequest{
		VolumeID:    m.volumeID,
		TargetPath:  target,
		CacheDir:    cacheDir,
		MountArgs:   args,
		LocalSocket: localSocket,
	}

	if _, err := m.client.Mount(ctx, req); err != nil {
		return nil, err
	}

	return &mountServiceUnmounter{
		client:   m.client,
		volumeID: m.volumeID,
	}, nil
}

func (u *mountServiceUnmounter) Unmount(ctx context.Context) error {
	_, err := u.client.Unmount(ctx, &mountmanager.UnmountRequest{VolumeID: u.volumeID})
	return err
}
```

Add `"context"` to the imports.

- [ ] **Step 2: Update Volume.Stage and Volume.Unstage to take context**

In `drivers/seaweedfs-csi-driver/pkg/driver/volume.go`, update `Stage` and `Unstage` and any internal calls. Replace these methods (read the current file first to find their exact location and surrounding code):

```go
func (vol *Volume) Stage(ctx context.Context, stagingTargetPath string) error {
	if isMnt, err := checkMount(stagingTargetPath); err != nil {
		return err
	} else if isMnt {
		glog.Infof("volume %s is already a mount point at %s", vol.VolumeId, stagingTargetPath)
		return nil
	}

	if u, err := vol.mounter.Mount(ctx, stagingTargetPath); err == nil {
		vol.unmounter = u
		return nil
	} else {
		return err
	}
}

func (vol *Volume) Unstage(ctx context.Context, stagingTargetPath string) error {
	if vol.unmounter != nil {
		if err := vol.unmounter.Unmount(ctx); err != nil {
			return err
		}
	}
	return nil
}
```

(If `Unstage` does additional work — read the current implementation and preserve it; only the `Unmount` call needs the new ctx parameter.)

Add `"context"` to the imports if not already present.

- [ ] **Step 3: Update nodeserver.go callers**

In `drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go`, update `stageNewVolume` to take and propagate a context:

```go
func (ns *NodeServer) stageNewVolume(ctx context.Context, volumeID, stagingTargetPath string, volContext map[string]string, readOnly bool) (*Volume, error) {
	mounter, err := newMounter(volumeID, readOnly, ns.Driver, volContext)
	if err != nil {
		return nil, err
	}

	volume := NewVolume(volumeID, mounter, ns.Driver)
	if err := volume.Stage(ctx, stagingTargetPath); err != nil {
		return nil, err
	}
	// ...rest of function unchanged, but any volume.Unstage() calls also gain ctx
	// ...
}
```

Then update both call sites in nodeserver.go (lines ~88 and ~164 — verify with grep) to pass `ctx`:

```bash
grep -n "stageNewVolume\|\.Stage(\|\.Unstage(" drivers/seaweedfs-csi-driver/pkg/driver/nodeserver.go
```

For each match, add `ctx` as the first argument. The `ctx` is already in scope inside `NodeStageVolume`, `NodePublishVolume`, etc. — those gRPC handlers receive it as their first parameter.

- [ ] **Step 4: Find any other callers across the package**

```bash
cd drivers/seaweedfs-csi-driver
grep -rn "\.Mount(\|\.Unmount()\|\.Stage(\|\.Unstage(" pkg/driver/
```

Update every match that hits the `Volume` or `Mounter` types to pass `ctx`. If the call site doesn't have a `ctx` in scope, use `context.TODO()` and leave a `// TODO(socket-retry): plumb real ctx` comment — but only as a last resort. Most call sites should already have one from the gRPC handler.

- [ ] **Step 5: Build the package**

```bash
cd drivers/seaweedfs-csi-driver
go build ./...
```

Expected: no errors. Compiler will catch any missed call site.

- [ ] **Step 6: Run all tests**

```bash
go test ./... -count=1
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/driver/
git commit -m "refactor(csi): thread context through Mounter, Volume, and NodeServer"
```

---

## Task 7: K8s Event recorder

**Files:**
- Create: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_events.go`
- Modify: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go`
- Modify: `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go`

- [ ] **Step 1: Write the failing env-fallback test**

Append to `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go`:

```go
func TestNewEventRecorder_NoEnv(t *testing.T) {
	t.Setenv("POD_NAME", "")
	t.Setenv("POD_NAMESPACE", "")
	rec := NewEventRecorder()
	if rec != nil {
		t.Errorf("NewEventRecorder() = %v, want nil when POD_NAME/POD_NAMESPACE unset", rec)
	}
}

func TestNewEventRecorder_NoCluster(t *testing.T) {
	t.Setenv("POD_NAME", "csi-node-test")
	t.Setenv("POD_NAMESPACE", "default")
	// rest.InClusterConfig() will fail outside a pod — recorder should
	// return nil, not panic.
	rec := NewEventRecorder()
	if rec != nil {
		t.Errorf("NewEventRecorder() = %v, want nil outside in-cluster", rec)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd drivers/seaweedfs-csi-driver
go test ./pkg/mountmanager/ -run TestNewEventRecorder
```

Expected: compile error `undefined: NewEventRecorder`.

- [ ] **Step 3: Write client_events.go**

Create `drivers/seaweedfs-csi-driver/pkg/mountmanager/client_events.go`:

```go
package mountmanager

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/seaweedfs/seaweedfs/weed/glog"
	corev1 "k8s.io/api/core/v1"
	eventsv1 "k8s.io/api/events/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// EventRecorder emits k8s Events on the csi-node Pod that owns this
// process. It is intentionally nilable: if env vars are missing or the
// in-cluster config is unavailable, NewEventRecorder returns nil and
// callers must skip recording. This is the graceful-degrade contract.
type EventRecorder struct {
	client    kubernetes.Interface
	namespace string
	podName   string
	hostName  string
}

// NewEventRecorder reads POD_NAME and POD_NAMESPACE from the environment
// (downward API), constructs an in-cluster client, and returns a
// recorder ready for use. Returns nil on any failure — never an error.
func NewEventRecorder() *EventRecorder {
	podName := os.Getenv("POD_NAME")
	ns := os.Getenv("POD_NAMESPACE")
	if podName == "" || ns == "" {
		glog.V(2).Infof("event recorder disabled: POD_NAME or POD_NAMESPACE not set")
		return nil
	}
	cfg, err := rest.InClusterConfig()
	if err != nil {
		glog.V(2).Infof("event recorder disabled: not running in-cluster: %v", err)
		return nil
	}
	cli, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		glog.V(2).Infof("event recorder disabled: kubernetes.NewForConfig: %v", err)
		return nil
	}
	host, _ := os.Hostname()
	return &EventRecorder{
		client:    cli,
		namespace: ns,
		podName:   podName,
		hostName:  host,
	}
}

// RecordMountServiceUnreachable emits a Warning Event on the csi-node
// Pod after the dial retry budget has been exhausted.
func (r *EventRecorder) RecordMountServiceUnreachable(endpoint string, elapsed time.Duration, cause error) {
	if r == nil {
		return
	}
	now := metav1.NewTime(time.Now())
	ev := &eventsv1.Event{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: "mount-service-unreachable-",
			Namespace:    r.namespace,
		},
		EventTime:           metav1.NewMicroTime(time.Now()),
		ReportingController: "seaweedfs-csi-driver",
		ReportingInstance:   r.hostName,
		Type:                corev1.EventTypeWarning,
		Reason:              "MountServiceUnreachable",
		Action:              "DialRetryExhausted",
		Note:                fmt.Sprintf("mount service at %s unreachable after %s during RPC: %v", endpoint, elapsed, cause),
		Regarding: corev1.ObjectReference{
			Kind:      "Pod",
			Name:      r.podName,
			Namespace: r.namespace,
		},
	}
	_ = now // events.k8s.io/v1 uses EventTime, not LastTimestamp
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := r.client.EventsV1().Events(r.namespace).Create(ctx, ev, metav1.CreateOptions{}); err != nil {
		glog.Warningf("failed to record k8s Event: %v", err)
	}
}
```

- [ ] **Step 4: Wire EventRecorder into Client**

In `drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go`, add the field to `Client`:

```go
type Client struct {
	httpClient *http.Client
	baseURL    string
	endpoint   string
	retry      clientRetryConfig
	events     *EventRecorder // nilable; nil means event emission is skipped
}
```

In `NewClient`, add the recorder construction at the end:

```go
return &Client{
	httpClient: &http.Client{
		Timeout:   30 * time.Second,
		Transport: transport,
	},
	baseURL:  "http://unix",
	endpoint: endpoint,
	retry:    defaultRetryConfig(),
	events:   NewEventRecorder(),
}, nil
```

- [ ] **Step 5: Call the recorder from doPost on exhaustion**

In `client.go`, inside `doPost`, in the budget-exhausted branch, add the recorder call **after** the metric increment but **before** the return:

```go
if errors.Is(pollErr, context.DeadlineExceeded) && lastErr != nil {
	dialRetriesTotal.WithLabelValues("exhausted").Inc()
	dialRetryDurationSeconds.Observe(elapsed.Seconds())
	glog.Errorf("mount service at %s unreachable after %s, giving up; kubelet will retry", c.endpoint, elapsed)
	c.events.RecordMountServiceUnreachable(c.endpoint, elapsed, lastErr)
	return fmt.Errorf("mount service at %s unreachable after %s: %w", c.endpoint, elapsed, lastErr)
}
```

(Calling `RecordMountServiceUnreachable` on a `nil` `*EventRecorder` is safe — the method receives by pointer and checks for nil at the top.)

- [ ] **Step 6: Run tests**

```bash
cd drivers/seaweedfs-csi-driver
go test ./pkg/mountmanager/... -count=1
```

Expected: PASS, including the two new TestNewEventRecorder subtests.

- [ ] **Step 7: Commit**

```bash
git add drivers/seaweedfs-csi-driver/pkg/mountmanager/client_events.go drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go drivers/seaweedfs-csi-driver/pkg/mountmanager/client_retry_test.go
git commit -m "feat(csi/retry): k8s Event on dial retry exhaustion"
```

---

## Task 8: Metrics HTTP server in csi-driver main.go

**Files:**
- Modify: `drivers/seaweedfs-csi-driver/cmd/seaweedfs-csi-driver/main.go`

- [ ] **Step 1: Add the --metricsPort flag**

In the `var (...)` flag block of `main.go`, add:

```go
metricsPort = flag.Int("metricsPort", 9808, "HTTP port for /metrics; 0 disables the metrics server")
```

- [ ] **Step 2: Add the metrics server startup**

After flag parsing but **before** `drv.Run()`, add:

```go
if *metricsPort > 0 {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(metrics.Registry, promhttp.HandlerOpts{}))
	addr := fmt.Sprintf(":%d", *metricsPort)
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		glog.Infof("metrics server listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			glog.Errorf("metrics server failed: %v", err)
		}
	}()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()
}
```

- [ ] **Step 3: Add the new imports**

In the `import (...)` block of `main.go`, add:

```go
"context"
"net/http"
"time"

"github.com/prometheus/client_golang/prometheus/promhttp"
"sigs.k8s.io/controller-runtime/pkg/metrics"
```

- [ ] **Step 4: Build the binary**

```bash
cd drivers/seaweedfs-csi-driver
go build ./cmd/seaweedfs-csi-driver/
```

Expected: no errors.

- [ ] **Step 5: Smoke-test the binary locally**

```bash
./seaweedfs-csi-driver --version
```

Expected: prints version JSON. Then clean up the binary:

```bash
rm -f seaweedfs-csi-driver
```

- [ ] **Step 6: Commit**

```bash
git add drivers/seaweedfs-csi-driver/cmd/seaweedfs-csi-driver/main.go
git commit -m "feat(csi): /metrics http server in csi-driver main"
```

---

## Task 9: Build images locally as v0.1.2

**Files:**
- None modified (build only)

- [ ] **Step 1: Inspect the current Makefile build target**

```bash
cd drivers/seaweedfs-csi-driver
grep -A2 "^container" Makefile
```

Expected: see the `container`, `container-csi`, `container-mount`, `container-recycler` targets.

- [ ] **Step 2: Build all three images for the host architecture**

```bash
cd drivers/seaweedfs-csi-driver
VERSION=v0.1.2 REGISTRY_NAME=registry.brmartin.co.uk/ben make container
```

Expected: docker builds all three images. On completion:

```bash
docker images | grep registry.brmartin.co.uk/ben | grep v0.1.2
```

Expected: three lines — `seaweedfs-csi-driver:v0.1.2`, `seaweedfs-mount:v0.1.2`, `seaweedfs-consumer-recycler:v0.1.2`.

- [ ] **Step 3: Build for the other architecture**

The cluster has both amd64 (hestia) and arm64 (heracles, nyx). The Makefile is host-arch only today. For the non-host architecture, use buildx manually:

```bash
cd drivers/seaweedfs-csi-driver
HOST_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
OTHER_ARCH=$([ "$HOST_ARCH" = "amd64" ] && echo arm64 || echo amd64)
echo "host=$HOST_ARCH other=$OTHER_ARCH"

for component in seaweedfs-csi-driver seaweedfs-mount seaweedfs-consumer-recycler; do
  docker buildx build \
    --platform "linux/$OTHER_ARCH" \
    --tag "registry.brmartin.co.uk/ben/${component}:v0.1.2-${OTHER_ARCH}" \
    --load \
    -f "cmd/${component}/Dockerfile.dev" \
    .
done
```

(If `Dockerfile.dev` doesn't exist for the recycler, use `cmd/seaweedfs-consumer-recycler/Dockerfile`. Check first with `ls cmd/*/Dockerfile*`.)

After both arches build, re-tag the host-arch images so all six are present:

```bash
for component in seaweedfs-csi-driver seaweedfs-mount seaweedfs-consumer-recycler; do
  docker tag "registry.brmartin.co.uk/ben/${component}:v0.1.2" "registry.brmartin.co.uk/ben/${component}:v0.1.2-${HOST_ARCH}"
done
docker images | grep v0.1.2
```

Expected: six images, one of each component for each architecture.

- [ ] **Step 4: No commit (build artifacts only)**

---

## Task 10: Sideload images to all three nodes

**Files:**
- None modified (transfer only)

- [ ] **Step 1: Save images to tarballs**

```bash
mkdir -p /tmp/sw-images
for component in seaweedfs-csi-driver seaweedfs-mount seaweedfs-consumer-recycler; do
  for arch in amd64 arm64; do
    docker save "registry.brmartin.co.uk/ben/${component}:v0.1.2-${arch}" -o "/tmp/sw-images/${component}-${arch}.tar"
  done
done
ls -lh /tmp/sw-images/
```

Expected: six .tar files.

- [ ] **Step 2: Sideload to hestia (amd64)**

```bash
for component in seaweedfs-csi-driver seaweedfs-mount seaweedfs-consumer-recycler; do
  scp /tmp/sw-images/${component}-amd64.tar ben@hestia:/tmp/
  ssh ben@hestia "sudo k3s ctr images import /tmp/${component}-amd64.tar && sudo k3s ctr images tag registry.brmartin.co.uk/ben/${component}:v0.1.2-amd64 registry.brmartin.co.uk/ben/${component}:v0.1.2 && rm /tmp/${component}-amd64.tar"
done
ssh ben@hestia "sudo k3s ctr images list | grep v0.1.2"
```

Expected: three images listed on hestia.

- [ ] **Step 3: Sideload to heracles (arm64)**

```bash
for component in seaweedfs-csi-driver seaweedfs-mount seaweedfs-consumer-recycler; do
  scp /tmp/sw-images/${component}-arm64.tar ben@heracles:/tmp/
  ssh ben@heracles "sudo k3s ctr images import /tmp/${component}-arm64.tar && sudo k3s ctr images tag registry.brmartin.co.uk/ben/${component}:v0.1.2-arm64 registry.brmartin.co.uk/ben/${component}:v0.1.2 && rm /tmp/${component}-arm64.tar"
done
ssh ben@heracles "sudo k3s ctr images list | grep v0.1.2"
```

- [ ] **Step 4: Sideload to nyx (arm64)**

```bash
for component in seaweedfs-csi-driver seaweedfs-mount seaweedfs-consumer-recycler; do
  scp /tmp/sw-images/${component}-arm64.tar ben@nyx:/tmp/
  ssh ben@nyx "sudo k3s ctr images import /tmp/${component}-arm64.tar && sudo k3s ctr images tag registry.brmartin.co.uk/ben/${component}:v0.1.2-arm64 registry.brmartin.co.uk/ben/${component}:v0.1.2 && rm /tmp/${component}-arm64.tar"
done
ssh ben@nyx "sudo k3s ctr images list | grep v0.1.2"
```

- [ ] **Step 5: Clean up local tarballs**

```bash
rm -rf /tmp/sw-images/
```

- [ ] **Step 6: No commit (deploy artifacts only)**

---

## Task 11: Terraform — bump image tag variables

**Files:**
- Modify: `modules-k8s/seaweedfs/variables.tf`

- [ ] **Step 1: Update all three image-tag defaults**

Edit `modules-k8s/seaweedfs/variables.tf`. Replace these three default values:

- `csi_driver_image_tag` default: `"v1.4.8-split"` → `"v0.1.2"`
- `csi_mount_image_tag` default: `"v1.4.8-split"` → `"v0.1.2"`
- `consumer_recycler_image_tag` default: `"v0.1.1"` → `"v0.1.2"`

- [ ] **Step 2: Verify the file**

```bash
grep -A1 "image_tag\"" modules-k8s/seaweedfs/variables.tf
```

Expected: all three defaults show `"v0.1.2"`.

- [ ] **Step 3: Commit**

```bash
git add modules-k8s/seaweedfs/variables.tf
git commit -m "chore(seaweedfs): bump monorepo image tags to v0.1.2"
```

---

## Task 12: Terraform — csi.tf metrics port + downward API + scrape annotations

**Files:**
- Modify: `modules-k8s/seaweedfs/csi.tf`

- [ ] **Step 1: Locate the csi-node DaemonSet pod template**

```bash
grep -n "seaweedfs-csi-node\|kubernetes_daemon_set" modules-k8s/seaweedfs/csi.tf | head
```

Expected: a `kubernetes_daemon_set` resource for csi-node and a corresponding pod template with a `csi-seaweedfs` container at line ~237.

- [ ] **Step 2: Add the metrics container port**

Inside the csi-node `csi-seaweedfs` container block (around line 238 — verify by reading the file), add a `port` block alongside any existing ones:

```hcl
port {
  name           = "metrics"
  container_port = 9808
  protocol       = "TCP"
}
```

- [ ] **Step 3: Add the downward-API env vars**

Inside the same container block, add the `POD_NAME` and `POD_NAMESPACE` env vars (alongside the existing `NODE_ID` env):

```hcl
env {
  name = "POD_NAME"
  value_from {
    field_ref {
      field_path = "metadata.name"
    }
  }
}
env {
  name = "POD_NAMESPACE"
  value_from {
    field_ref {
      field_path = "metadata.namespace"
    }
  }
}
```

- [ ] **Step 4: Add prometheus scrape annotations on the pod template**

Inside the csi-node DaemonSet's `spec → template → metadata` block, add or extend the `annotations` block to include:

```hcl
annotations = {
  "prometheus.io/scrape" = "true"
  "prometheus.io/port"   = "9808"
  "prometheus.io/path"   = "/metrics"
}
```

(If an `annotations` block already exists, merge these three keys into it.)

- [ ] **Step 5: Run terraform validate**

```bash
cd modules-k8s/seaweedfs
terraform fmt -check -diff
terraform validate
cd ../..
```

Expected: `Success! The configuration is valid.`

If `terraform validate` fails because the module isn't initialised standalone, run validate from the root that consumes this module instead:

```bash
terraform validate
```

- [ ] **Step 6: Commit**

```bash
git add modules-k8s/seaweedfs/csi.tf
git commit -m "feat(seaweedfs/csi): expose metrics port + downward-API env on csi-node"
```

---

## Task 13: Terraform — RBAC audit and grant events permission

**Files:**
- Modify (conditional): `modules-k8s/seaweedfs/csi-rbac.tf`

- [ ] **Step 1: Audit the existing csi-node ServiceAccount and ClusterRole**

```bash
grep -nA20 "csi.*node\|node.*csi" modules-k8s/seaweedfs/csi-rbac.tf | head -60
```

Identify the ClusterRole (or Role) that the csi-node ServiceAccount binds to.

- [ ] **Step 2: Check whether `events` permission already exists**

```bash
grep -n '"events"\|events\.k8s\.io' modules-k8s/seaweedfs/csi-rbac.tf
```

If you find a rule granting `create` on `events` in `events.k8s.io`, skip to Step 5.

- [ ] **Step 3: Add the events.k8s.io rule**

If no such rule exists, add a new rule to the csi-node ClusterRole (or, if csi-node has no ClusterRole, to a new namespaced Role bound to the csi-node ServiceAccount in the `default` namespace):

```hcl
rule {
  api_groups = ["events.k8s.io"]
  resources  = ["events"]
  verbs      = ["create", "patch"]
}
```

- [ ] **Step 4: Validate**

```bash
cd modules-k8s/seaweedfs
terraform fmt -check -diff
terraform validate
cd ../..
```

- [ ] **Step 5: Commit (only if step 3 made changes)**

```bash
git status modules-k8s/seaweedfs/csi-rbac.tf
# if modified:
git add modules-k8s/seaweedfs/csi-rbac.tf
git commit -m "feat(seaweedfs/rbac): grant csi-node create on events.k8s.io"
```

---

## Task 14: Terraform plan and apply

**Files:**
- None modified

- [ ] **Step 1: Run terraform plan**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
terraform plan -out=/tmp/csi-retry.tfplan
```

Expected changes (review carefully):
- `kubernetes_daemon_set.csi_node` (or similar) — image tag bump, new env vars, new container port, new pod annotations
- `kubernetes_deployment.csi_controller` — image tag bump
- `kubernetes_daemon_set.consumer_recycler` (or similar) — image tag bump
- (conditional) `kubernetes_cluster_role.*` — events.k8s.io rule

If the plan shows unrelated drift, stop and investigate.

- [ ] **Step 2: Apply**

```bash
terraform apply /tmp/csi-retry.tfplan
rm /tmp/csi-retry.tfplan
```

Expected: apply completes. Note: the controller Deployment will roll automatically; the recycler DaemonSet will roll automatically (acceptable — image content unchanged); the csi-node DaemonSet uses `OnDelete`, so it won't cycle yet.

- [ ] **Step 3: Verify the new spec is applied (no pods cycled yet)**

```bash
kubectl -n default get ds/seaweedfs-csi-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="csi-seaweedfs")].image}'
```

Expected: `registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v0.1.2`.

```bash
kubectl -n default get pods -l app=seaweedfs-csi-node -o jsonpath='{.items[*].spec.containers[?(@.name=="csi-seaweedfs")].image}'
```

Expected: still showing `v1.4.8-split` on all three pods (cycle pending).

```bash
kubectl -n default get pods -l app=seaweedfs-consumer-recycler -o jsonpath='{.items[*].spec.containers[*].image}'
```

Expected: all three recycler pods now on `:v0.1.2`.

- [ ] **Step 4: No commit (terraform state changes only)**

---

## Task 15: Cycle csi-node pods one node at a time

**Files:**
- None modified

- [ ] **Step 1: Cycle nyx (arm64, lightest load) first**

```bash
kubectl -n default delete pod -l app=seaweedfs-csi-node --field-selector spec.nodeName=nyx
kubectl -n default wait --for=condition=Ready pod -l app=seaweedfs-csi-node --field-selector spec.nodeName=nyx --timeout=120s
```

- [ ] **Step 2: Verify nyx is on v0.1.2 and metrics endpoint is reachable**

```bash
NYX_POD=$(kubectl -n default get pods -l app=seaweedfs-csi-node --field-selector spec.nodeName=nyx -o jsonpath='{.items[0].metadata.name}')
kubectl -n default get pod $NYX_POD -o jsonpath='{.spec.containers[?(@.name=="csi-seaweedfs")].image}{"\n"}'
kubectl -n default port-forward pod/$NYX_POD 9808:9808 &
PF_PID=$!
sleep 2
curl -s http://localhost:9808/metrics | grep -E "seaweedfs_csi_dial|seaweedfs_recycler" | head -5
kill $PF_PID
```

Expected: image tag is `v0.1.2`, curl shows the new dial-retry metrics (zero values, since no retries have happened yet).

- [ ] **Step 3: Smoke test 1 — passive observation of next NodePublishVolume**

```bash
kubectl -n default logs $NYX_POD -c csi-seaweedfs --since=5m | grep -i "mount service" || echo "no warnings yet (expected if no PVCs mounted recently)"
```

Force a mount by deleting any one consumer pod on nyx that uses a seaweedfs PVC:

```bash
kubectl get pods --all-namespaces -o json | \
  jq -r '.items[] | select(.spec.nodeName=="nyx" and (.spec.volumes // [] | map(select(.persistentVolumeClaim)) | length > 0)) | "\(.metadata.namespace) \(.metadata.name)"' | \
  head -1
```

Pick one of those pods and delete it:

```bash
kubectl -n <ns> delete pod <pod-name>
kubectl -n default logs $NYX_POD -c csi-seaweedfs --since=2m | grep -i "mount service\|publish"
```

Expected: `NodePublishVolume` succeeds; if any retry warnings appear, they recover within seconds.

- [ ] **Step 4: Smoke test 2 — forced retry exhaustion**

Patch the seaweedfs-mount DaemonSet so it cannot run on nyx:

```bash
kubectl -n default patch ds seaweedfs-mount --type='strategic' --patch='{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"NotIn","values":["nyx"]}]}]}}}}}}}'
kubectl -n default delete pod -l component=seaweedfs-mount --field-selector spec.nodeName=nyx
sleep 5
ssh ben@nyx "sudo ls /var/lib/seaweedfs-mount/" || echo "socket dir empty as expected"
```

Now force a NodePublishVolume by deleting another consumer pod on nyx:

```bash
kubectl get pods --all-namespaces -o json | \
  jq -r '.items[] | select(.spec.nodeName=="nyx" and (.spec.volumes // [] | map(select(.persistentVolumeClaim)) | length > 0)) | "\(.metadata.namespace) \(.metadata.name)"' | \
  head -1
# delete the resulting pod
kubectl -n <ns> delete pod <pod-name>
```

Wait 35 seconds, then check for the warning event and the exhausted metric:

```bash
sleep 35
kubectl -n default get events --field-selector reason=MountServiceUnreachable
kubectl -n default port-forward pod/$NYX_POD 9808:9808 &
PF_PID=$!
sleep 2
curl -s http://localhost:9808/metrics | grep seaweedfs_csi_dial
kill $PF_PID
```

Expected: at least one `MountServiceUnreachable` event listed, `seaweedfs_csi_dial_retries_total{outcome="exhausted"}` is ≥1.

- [ ] **Step 5: Recovery — un-patch the mount DaemonSet**

```bash
kubectl -n default patch ds seaweedfs-mount --type='strategic' --patch='{"spec":{"template":{"spec":{"affinity":null}}}}'
kubectl -n default wait --for=condition=Ready pod -l component=seaweedfs-mount --field-selector spec.nodeName=nyx --timeout=120s
```

Wait for the kubelet retry on the affected consumer to succeed (≤2 min). Then verify the `recovered` metric ticks up on the next mount-needing pod:

```bash
kubectl -n default port-forward pod/$NYX_POD 9808:9808 &
PF_PID=$!
sleep 2
curl -s http://localhost:9808/metrics | grep seaweedfs_csi_dial
kill $PF_PID
```

Expected: `seaweedfs_csi_dial_retries_total{outcome="recovered"}` is ≥1 after the next consumer-restart-driven NodePublishVolume.

- [ ] **Step 6: Cycle hestia**

Repeat Steps 1-2 for hestia (skip the smoke tests — once is enough):

```bash
kubectl -n default delete pod -l app=seaweedfs-csi-node --field-selector spec.nodeName=hestia
kubectl -n default wait --for=condition=Ready pod -l app=seaweedfs-csi-node --field-selector spec.nodeName=hestia --timeout=120s
HESTIA_POD=$(kubectl -n default get pods -l app=seaweedfs-csi-node --field-selector spec.nodeName=hestia -o jsonpath='{.items[0].metadata.name}')
kubectl -n default get pod $HESTIA_POD -o jsonpath='{.spec.containers[?(@.name=="csi-seaweedfs")].image}{"\n"}'
```

Expected: image is `v0.1.2`. Check logs for any retry warnings:

```bash
kubectl -n default logs $HESTIA_POD -c csi-seaweedfs --since=5m | grep -i "mount service" || echo "clean"
```

- [ ] **Step 7: Cycle heracles**

Same as Step 6 but for heracles:

```bash
kubectl -n default delete pod -l app=seaweedfs-csi-node --field-selector spec.nodeName=heracles
kubectl -n default wait --for=condition=Ready pod -l app=seaweedfs-csi-node --field-selector spec.nodeName=heracles --timeout=120s
HERACLES_POD=$(kubectl -n default get pods -l app=seaweedfs-csi-node --field-selector spec.nodeName=heracles -o jsonpath='{.items[0].metadata.name}')
kubectl -n default get pod $HERACLES_POD -o jsonpath='{.spec.containers[?(@.name=="csi-seaweedfs")].image}{"\n"}'
kubectl -n default logs $HERACLES_POD -c csi-seaweedfs --since=5m | grep -i "mount service" || echo "clean"
```

- [ ] **Step 8: No commit (deployment validation only)**

---

## Task 16: Mark Gap #5 shipped in production-readiness notes

**Files:**
- Modify: `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`

- [ ] **Step 1: Update the header banner**

In `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`, after the existing Gap #2 banner at the top, add a new banner for Gap #5:

```markdown
> **Gap #5 shipped 2026-04-09** — `seaweedfs-csi-driver` v0.1.2 deployed across all 3 nodes. `pkg/mountmanager.Client.doPost()` now retries transport-level dial failures (ENOENT/ECONNREFUSED) for up to 30s before surfacing an error to kubelet, with Prometheus metrics on the new `:9808/metrics` endpoint and `MountServiceUnreachable` k8s Events on retry exhaustion. Validated end-to-end on nyx with both passive (mount service ready) and forced (mount service unschedulable) paths.
```

- [ ] **Step 2: Update the Gap #5 section in place**

Find the `## Gap 5: Startup ordering — csi-node dials socket before seaweedfs-mount ready` heading. Replace it with:

```markdown
## Gap 5: Startup ordering — csi-node dials socket before seaweedfs-mount ready — **SHIPPED 2026-04-09**

**Shipped as:** retry loop in `drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go` at the `doPost()` layer. Image `registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v0.1.2` (multi-arch, sideloaded). Plan: `docs/superpowers/plans/2026-04-09-seaweedfs-csi-socket-retry.md`. Spec: `docs/superpowers/specs/2026-04-09-seaweedfs-csi-socket-retry-design.md`.

**How it works:**
- `wait.PollUntilContextTimeout` wraps the http call in `doPost()` with a 30-second budget and 1-second interval.
- `shouldRetryDial` classifier matches `ENOENT`, `ECONNREFUSED`, and `net.OpError` dial errors only — HTTP 4xx/5xx and context cancellations propagate immediately.
- Metrics: `seaweedfs_csi_dial_retries_total{outcome=recovered|exhausted}` + `seaweedfs_csi_dial_retry_duration_seconds` histogram on the new csi-node `:9808/metrics` endpoint.
- K8s Event `Warning/MountServiceUnreachable` on retry exhaustion (graceful-degrade if RBAC missing).

**Reframing of the original gap:** Reading the actual code showed the driver does NOT crash on a missing socket — `mountmanager.NewClient` is lazy and the first dial happens inside `doPost`. The real symptom was kubelet's minute-scale exponential backoff after a single 30-second http-client timeout. The fix removes that backoff by recovering inside the call.

---

### Original planning notes (preserved for history)
```

(Then leave the existing original-planning-notes content under the new H3 separator, exactly as it was.)

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md
git commit -m "docs(seaweedfs): mark Gap #5 (csi socket retry) as shipped"
```

---

## Task 17: Final verification and merge prep

**Files:**
- None modified

- [ ] **Step 1: Run all driver tests one more time**

```bash
cd drivers/seaweedfs-csi-driver
go test ./... -count=1
```

Expected: PASS.

- [ ] **Step 2: Verify the branch is clean**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 3: Show the commit list for the PR**

```bash
git log --oneline main..feat/csi-socket-retry
```

Expected: ~10 commits — classifier, metrics, doPost retry, ctx propagation, events, main.go metrics server, image tag bump, terraform csi.tf, terraform RBAC (if needed), notes update.

- [ ] **Step 4: Final manual cluster-wide check**

```bash
for node in nyx hestia heracles; do
  echo "=== $node ==="
  POD=$(kubectl -n default get pods -l app=seaweedfs-csi-node --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}')
  kubectl -n default get pod $POD -o jsonpath='{.status.phase} {.spec.containers[?(@.name=="csi-seaweedfs")].image}{"\n"}'
done
```

Expected: each node shows `Running registry.brmartin.co.uk/ben/seaweedfs-csi-driver:v0.1.2`.

- [ ] **Step 5: Branch ready for merge**

Plan complete. The branch can be merged into `main` with a normal merge commit (matches the consumer-recycler shipping pattern).
