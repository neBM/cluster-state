package mountmanager

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"time"
)

func HasLiveService(ctx context.Context, endpoint string) (bool, error) {
	scheme, address, err := ParseEndpoint(endpoint)
	if err != nil {
		return false, err
	}
	if scheme != "unix" {
		return false, fmt.Errorf("unsupported endpoint scheme: %s", scheme)
	}

	dialer := &net.Dialer{}
	client := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return dialer.DialContext(ctx, "unix", address)
			},
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://unix/healthz", nil)
	if err != nil {
		return false, fmt.Errorf("build health probe request: %w", err)
	}

	resp, err := client.Do(req)
	if err != nil {
		if shouldRetryDial(err) {
			return false, nil
		}
		return false, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return true, nil
	}

	return false, fmt.Errorf("unexpected mount service health status: %s", resp.Status)
}
