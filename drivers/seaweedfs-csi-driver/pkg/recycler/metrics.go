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
