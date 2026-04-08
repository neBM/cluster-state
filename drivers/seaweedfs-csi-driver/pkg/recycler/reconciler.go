package recycler

import (
	"context"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// Reconciler wires the two signal paths into a shared cycling pipeline.
type Reconciler struct {
	Client    client.Client
	NodeName  string
	Lookup    *PVLookup
	Cycler    *Cycler
	Baseline  *BaselineTracker
	ColdStart *ColdStartWindow
	Recorder  record.EventRecorder // may be nil in tests
	Log       logr.Logger
}

// HandleMountDaemonEvent is invoked by the Pod informer whenever a
// seaweedfs-mount pod on this node transitions.
func (r *Reconciler) HandleMountDaemonEvent(ctx context.Context, mountPod *corev1.Pod) {
	logger := r.logger(ctx)

	var restartCount int32
	for _, cs := range mountPod.Status.ContainerStatuses {
		if cs.Name == "seaweedfs-mount" {
			restartCount = cs.RestartCount
			break
		}
	}

	triggered := r.Baseline.ObserveRestart(mountPod.UID, restartCount)
	if !triggered {
		return
	}

	if r.ColdStart.Suppressed(time.Now()) {
		ColdStartSuppressedTotal.Inc()
		logger.Info("cold-start window suppressing Path A", "mountPod", mountPod.Name, "restartCount", restartCount)
		return
	}

	TriggersTotal.WithLabelValues("event").Inc()
	logger.Info("mount daemon restart detected, enumerating candidates",
		"mountPod", mountPod.Name, "restartCount", restartCount, "node", r.NodeName)

	candidates, err := r.Lookup.ListCandidates(ctx)
	if err != nil {
		logger.Error(err, "ListCandidates failed")
		return
	}
	if len(candidates) == 0 {
		logger.Info("no candidates to cycle")
		return
	}
	if r.Recorder != nil {
		r.Recorder.Eventf(mountPod, corev1.EventTypeNormal, "RecycleTriggered",
			"restart detected; cycling %d consumer pod(s) on node %s", len(candidates), r.NodeName)
	}
	r.Cycler.CycleBatch(ctx, candidates)
}

// HandleProbeFailure is invoked by the Prober for each unhealthy mountpoint.
// Not subject to the cold-start window.
func (r *Reconciler) HandleProbeFailure(ctx context.Context, mountpoint string) {
	logger := r.logger(ctx)
	TriggersTotal.WithLabelValues("probe").Inc()

	uid := ResolvePodUIDFromMountpoint(mountpoint)
	if uid == "" {
		logger.Info("could not resolve pod UID from mountpoint", "mountpoint", mountpoint)
		return
	}

	candidates, err := r.Lookup.ListCandidates(ctx)
	if err != nil {
		logger.Error(err, "ListCandidates failed")
		return
	}
	for i := range candidates {
		if string(candidates[i].UID) == uid {
			if r.Recorder != nil {
				r.Recorder.Eventf(&candidates[i], corev1.EventTypeWarning, "RecycledStaleMount",
					"FUSE mount %s failed probe, cycling", mountpoint)
			}
			if err := r.Cycler.CycleOne(ctx, &candidates[i]); err != nil {
				logger.Error(err, "CycleOne failed", "pod", candidates[i].Name)
			}
			return
		}
	}
	logger.Info("probe-failed mountpoint had no matching candidate pod", "mountpoint", mountpoint, "uid", uid)
}

func (r *Reconciler) logger(ctx context.Context) logr.Logger {
	if r.Log.GetSink() != nil {
		return r.Log
	}
	return log.FromContext(ctx)
}
