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
		[]string{"path"}, // "mount_restart" | "volume_restart" | "probe_failure"
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
			Help: "Recycler recovery actions suppressed by the cold-start window.",
		},
	)
	EvictionBlockedTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_eviction_blocked_total",
			Help: "Eviction calls blocked before fallback.",
		},
		[]string{"reason"}, // "pdb" | "other"
	)
	VolumeRefreshesTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_volume_refreshes_total",
			Help: "Node-local mount routing refresh attempts triggered by volume replacement.",
		},
		[]string{"result"}, // "started" | "succeeded" | "failed"
	)
	RolloutSmokeChecksTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "seaweedfs_recycler_rollout_smoke_checks_total",
			Help: "Recycler rollout-smoke outcomes for gated pod restarts.",
		},
		[]string{"outcome"}, // "passed" | "timeout" | "request_error" | "invalid_config"
	)
	RolloutSmokeWaitDurationSeconds = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "seaweedfs_recycler_rollout_smoke_wait_duration_seconds",
			Help:    "Time spent waiting on app-declared rollout smoke checks.",
			Buckets: prometheus.DefBuckets,
		},
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
		VolumeRefreshesTotal,
		RolloutSmokeChecksTotal,
		RolloutSmokeWaitDurationSeconds,
	)
}
