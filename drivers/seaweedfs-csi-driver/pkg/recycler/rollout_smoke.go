package recycler

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
)

const (
	RolloutSmokeHTTPURLAnnotation              = "seaweedfs.csi.brmartin.co.uk/rollout-smoke-http-url"
	RolloutSmokeHTTPExpectedStatusesAnnotation = "seaweedfs.csi.brmartin.co.uk/rollout-smoke-http-expected-statuses"

	defaultRolloutSmokePollInterval   = 5 * time.Second
	defaultRolloutSmokeTimeout        = 5 * time.Minute
	defaultRolloutSmokeRequestTimeout = 5 * time.Second
)

// RolloutSmoke blocks recycler-triggered pod cycling until an app-owned
// HTTP contract says the dependency path is back.
type RolloutSmoke interface {
	HasGate(pod *corev1.Pod) bool
	Wait(ctx context.Context, pod *corev1.Pod) (time.Duration, error)
}

// RolloutSmokeWaitError preserves the failure classification so the cycler can
// log, emit events, and count outcomes without guessing from string messages.
type RolloutSmokeWaitError struct {
	Outcome string
	Err     error
}

func (e *RolloutSmokeWaitError) Error() string {
	if e == nil {
		return "<nil>"
	}
	if e.Err == nil {
		return e.Outcome
	}
	return fmt.Sprintf("%s: %v", e.Outcome, e.Err)
}

func (e *RolloutSmokeWaitError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

type rolloutSmokeConfig struct {
	url              string
	expectedStatuses map[int]struct{}
}

// HTTPRolloutSmoker evaluates the pod's declared HTTP rollout smoke.
type HTTPRolloutSmoker struct {
	Client       *http.Client
	PollInterval time.Duration
	Timeout      time.Duration
}

func (s *HTTPRolloutSmoker) HasGate(pod *corev1.Pod) bool {
	if pod == nil || pod.Annotations == nil {
		return false
	}
	_, hasURL := pod.Annotations[RolloutSmokeHTTPURLAnnotation]
	_, hasStatuses := pod.Annotations[RolloutSmokeHTTPExpectedStatusesAnnotation]
	return hasURL || hasStatuses
}

func (s *HTTPRolloutSmoker) Wait(ctx context.Context, pod *corev1.Pod) (time.Duration, error) {
	start := time.Now()
	cfg, configured, err := parseRolloutSmokeConfig(pod)
	if err != nil {
		return time.Since(start), &RolloutSmokeWaitError{Outcome: "invalid_config", Err: err}
	}
	if !configured {
		return time.Since(start), nil
	}

	timeout := s.Timeout
	if timeout <= 0 {
		timeout = defaultRolloutSmokeTimeout
	}
	pollInterval := s.PollInterval
	if pollInterval <= 0 {
		pollInterval = defaultRolloutSmokePollInterval
	}
	client := s.Client
	if client == nil {
		client = &http.Client{Timeout: defaultRolloutSmokeRequestTimeout}
	}

	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var (
		lastStatus int
		lastErr    error
	)

	for {
		req, reqErr := http.NewRequestWithContext(waitCtx, http.MethodGet, cfg.url, nil)
		if reqErr != nil {
			return time.Since(start), &RolloutSmokeWaitError{Outcome: "invalid_config", Err: reqErr}
		}

		resp, doErr := client.Do(req)
		if doErr != nil {
			if waitCtx.Err() == nil {
				lastErr = doErr
			}
		} else {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			lastStatus = resp.StatusCode
			lastErr = nil
			if _, ok := cfg.expectedStatuses[resp.StatusCode]; ok {
				return time.Since(start), nil
			}
		}

		select {
		case <-waitCtx.Done():
			if ctx.Err() != nil {
				return time.Since(start), ctx.Err()
			}
			if lastErr != nil {
				return time.Since(start), &RolloutSmokeWaitError{
					Outcome: "request_error",
					Err:     fmt.Errorf("smoke GET %s failed until timeout: %w", cfg.url, lastErr),
				}
			}
			return time.Since(start), &RolloutSmokeWaitError{
				Outcome: "timeout",
				Err: fmt.Errorf("smoke GET %s never returned one of %s before timeout; last status=%d",
					cfg.url, formatExpectedStatuses(cfg.expectedStatuses), lastStatus),
			}
		case <-time.After(pollInterval):
		}
	}
}

func parseRolloutSmokeConfig(pod *corev1.Pod) (*rolloutSmokeConfig, bool, error) {
	if pod == nil || pod.Annotations == nil {
		return nil, false, nil
	}
	annotations := pod.Annotations
	urlValue, hasURL := annotations[RolloutSmokeHTTPURLAnnotation]
	statusesValue, hasStatuses := annotations[RolloutSmokeHTTPExpectedStatusesAnnotation]
	if !hasURL && !hasStatuses {
		return nil, false, nil
	}
	if !hasURL || strings.TrimSpace(urlValue) == "" {
		return nil, true, fmt.Errorf("missing %s", RolloutSmokeHTTPURLAnnotation)
	}
	if !hasStatuses || strings.TrimSpace(statusesValue) == "" {
		return nil, true, fmt.Errorf("missing %s", RolloutSmokeHTTPExpectedStatusesAnnotation)
	}

	parsedURL, err := url.Parse(strings.TrimSpace(urlValue))
	if err != nil {
		return nil, true, fmt.Errorf("parse %s: %w", RolloutSmokeHTTPURLAnnotation, err)
	}
	if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
		return nil, true, fmt.Errorf("%s must use http or https", RolloutSmokeHTTPURLAnnotation)
	}
	if parsedURL.Host == "" {
		return nil, true, fmt.Errorf("%s must include a host", RolloutSmokeHTTPURLAnnotation)
	}

	expectedStatuses, err := parseExpectedStatuses(statusesValue)
	if err != nil {
		return nil, true, err
	}

	return &rolloutSmokeConfig{
		url:              parsedURL.String(),
		expectedStatuses: expectedStatuses,
	}, true, nil
}

func parseExpectedStatuses(raw string) (map[int]struct{}, error) {
	parts := strings.Split(raw, ",")
	out := make(map[int]struct{}, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			return nil, fmt.Errorf("%s contains an empty status", RolloutSmokeHTTPExpectedStatusesAnnotation)
		}
		status, err := strconv.Atoi(trimmed)
		if err != nil {
			return nil, fmt.Errorf("parse %s=%q: %w", RolloutSmokeHTTPExpectedStatusesAnnotation, raw, err)
		}
		if status < 100 || status > 599 {
			return nil, fmt.Errorf("%s status %d out of range", RolloutSmokeHTTPExpectedStatusesAnnotation, status)
		}
		out[status] = struct{}{}
	}
	if len(out) == 0 {
		return nil, errors.New("no expected statuses configured")
	}
	return out, nil
}

func formatExpectedStatuses(statuses map[int]struct{}) string {
	codes := make([]int, 0, len(statuses))
	for code := range statuses {
		codes = append(codes, code)
	}
	sort.Ints(codes)

	ordered := make([]string, 0, len(codes))
	for _, code := range codes {
		ordered = append(ordered, strconv.Itoa(code))
	}
	return strings.Join(ordered, ",")
}
