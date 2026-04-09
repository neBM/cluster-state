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
