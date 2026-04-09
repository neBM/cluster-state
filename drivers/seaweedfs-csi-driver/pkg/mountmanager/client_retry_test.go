package mountmanager

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
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

// newUnixHTTPServer starts an http.Server bound to a unix socket at the
// returned path. The caller is responsible for calling close() to stop
// the server and remove the socket.
func newUnixHTTPServer(t *testing.T, handler http.Handler) (sockPath string, closeFn func()) {
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
	var (
		srvMu  sync.Mutex
		srv    *http.Server
		srvWG  sync.WaitGroup
	)
	srvWG.Add(1)
	go func() {
		defer srvWG.Done()
		time.Sleep(30 * time.Millisecond)
		ln, err := net.Listen("unix", sockPath)
		if err != nil {
			t.Errorf("delayed listen: %v", err)
			return
		}
		s := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		})}
		srvMu.Lock()
		srv = s
		srvMu.Unlock()
		_ = s.Serve(ln)
	}()
	defer func() {
		// Must close BEFORE waiting — Serve() blocks until Close() is called.
		srvMu.Lock()
		s := srv
		srvMu.Unlock()
		if s != nil {
			_ = s.Close()
		}
		srvWG.Wait()
		_ = os.Remove(sockPath)
	}()

	c := newClientForTest(t, sockPath)
	c.retry = clientRetryConfig{budget: 2 * time.Second, interval: 10 * time.Millisecond}
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
