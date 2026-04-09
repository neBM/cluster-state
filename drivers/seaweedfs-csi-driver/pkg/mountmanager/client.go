package mountmanager

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/seaweedfs/seaweedfs/weed/glog"
	"k8s.io/apimachinery/pkg/util/wait"
)

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
