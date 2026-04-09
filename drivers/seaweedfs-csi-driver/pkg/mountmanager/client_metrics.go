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
