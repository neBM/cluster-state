package recycler

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type fakeRolloutSmoke struct {
	gated   map[string]bool
	results map[string]fakeRolloutSmokeResult
	waits   []string
}

type fakeRolloutSmokeResult struct {
	duration time.Duration
	err      error
}

func (f *fakeRolloutSmoke) HasGate(pod *corev1.Pod) bool {
	return f.gated[pod.Name]
}

func (f *fakeRolloutSmoke) Wait(ctx context.Context, pod *corev1.Pod) (time.Duration, error) {
	f.waits = append(f.waits, pod.Name)
	if result, ok := f.results[pod.Name]; ok {
		return result.duration, result.err
	}
	return 0, nil
}

func TestCycler_CycleBatch_EvictsUngatedPodsBeforeSmokeGatedPods(t *testing.T) {
	ev := &fakeEvictor{}
	smoke := &fakeRolloutSmoke{
		gated: map[string]bool{
			"gated-app": true,
		},
		results: map[string]fakeRolloutSmokeResult{
			"gated-app": {duration: 25 * time.Millisecond},
		},
	}
	c := &Cycler{
		Evictor:          ev,
		Debounce:         NewDebouncer(time.Minute),
		EvictionRetry:    1 * time.Millisecond,
		EvictionDeadline: 10 * time.Millisecond,
		RolloutSmoke:     smoke,
	}

	c.CycleBatch(context.Background(), []corev1.Pod{
		*pod("gated-app", "nyx", "gated-app-data"),
		*pod("plain-app", "nyx", "plain-app-data"),
	})

	if len(smoke.waits) != 1 || smoke.waits[0] != "gated-app" {
		t.Fatalf("want smoke wait only for gated-app, got %v", smoke.waits)
	}
	if len(ev.attempts) != 2 {
		t.Fatalf("want 2 eviction attempts, got %d", len(ev.attempts))
	}
	if ev.attempts[0].Name != "plain-app" || ev.attempts[1].Name != "gated-app" {
		t.Fatalf("want ungated pod first then gated pod, got %v", ev.attempts)
	}
}

func TestCycler_CycleBatch_SmokeFailureSkipsEvictionWithoutDebounce(t *testing.T) {
	ev := &fakeEvictor{}
	smoke := &fakeRolloutSmoke{
		gated: map[string]bool{
			"iris": true,
		},
		results: map[string]fakeRolloutSmokeResult{
			"iris": {err: &RolloutSmokeWaitError{Outcome: "timeout", Err: errors.New("last status: 503")}},
		},
	}
	c := &Cycler{
		Evictor:          ev,
		Debounce:         NewDebouncer(time.Minute),
		EvictionRetry:    1 * time.Millisecond,
		EvictionDeadline: 10 * time.Millisecond,
		RolloutSmoke:     smoke,
	}

	pods := []corev1.Pod{*pod("iris", "heracles", "iris-image-cache-sw")}
	c.CycleBatch(context.Background(), pods)
	if len(ev.attempts) != 0 {
		t.Fatalf("smoke failure should skip eviction, got %d attempts", len(ev.attempts))
	}

	smoke.results["iris"] = fakeRolloutSmokeResult{duration: 10 * time.Millisecond}
	c.CycleBatch(context.Background(), pods)
	if len(ev.attempts) != 1 {
		t.Fatalf("successful retry should evict once, got %d attempts", len(ev.attempts))
	}
}

func TestHTTPRolloutSmoker_WaitsForAllowedStatus(t *testing.T) {
	var calls int
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 3 {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusForbidden)
	}))
	defer server.Close()

	smoker := &HTTPRolloutSmoker{
		Client:       server.Client(),
		PollInterval: 1 * time.Millisecond,
		Timeout:      100 * time.Millisecond,
	}

	duration, err := smoker.Wait(context.Background(), smokePod(server.URL, "403"))
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if duration <= 0 {
		t.Fatalf("want positive wait duration, got %s", duration)
	}
	if calls != 3 {
		t.Fatalf("want 3 calls before success, got %d", calls)
	}
}

func TestHTTPRolloutSmoker_InvalidAnnotationsFailClosed(t *testing.T) {
	smoker := &HTTPRolloutSmoker{
		PollInterval: 1 * time.Millisecond,
		Timeout:      10 * time.Millisecond,
	}

	_, err := smoker.Wait(context.Background(), smokePod("https://git.brmartin.co.uk/jwt/auth", "wat"))
	if err == nil {
		t.Fatal("expected invalid annotation error, got nil")
	}
	var smokeErr *RolloutSmokeWaitError
	if !errors.As(err, &smokeErr) {
		t.Fatalf("want RolloutSmokeWaitError, got %T", err)
	}
	if smokeErr.Outcome != "invalid_config" {
		t.Fatalf("want invalid_config outcome, got %q", smokeErr.Outcome)
	}
}

func TestHTTPRolloutSmoker_TransportErrorsSurfaceAsRequestError(t *testing.T) {
	smoker := &HTTPRolloutSmoker{
		Client: &http.Client{
			Transport: roundTripperFunc(func(req *http.Request) (*http.Response, error) {
				return nil, errors.New("dial tcp: connect: connection refused")
			}),
		},
		PollInterval: 1 * time.Millisecond,
		Timeout:      10 * time.Millisecond,
	}

	_, err := smoker.Wait(context.Background(), smokePod("https://git.brmartin.co.uk/jwt/auth", "401,403"))
	if err == nil {
		t.Fatal("expected request error, got nil")
	}
	var smokeErr *RolloutSmokeWaitError
	if !errors.As(err, &smokeErr) {
		t.Fatalf("want RolloutSmokeWaitError, got %T", err)
	}
	if smokeErr.Outcome != "request_error" {
		t.Fatalf("want request_error outcome, got %q", smokeErr.Outcome)
	}
}

func smokePod(url, statuses string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "smoke-pod",
			Namespace: "default",
			Annotations: map[string]string{
				RolloutSmokeHTTPURLAnnotation:              url,
				RolloutSmokeHTTPExpectedStatusesAnnotation: statuses,
			},
		},
	}
}

type roundTripperFunc func(req *http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}
