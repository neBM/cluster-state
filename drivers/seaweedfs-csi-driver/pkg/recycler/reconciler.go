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
	Client      client.Client
	NodeName    string
	Lookup      *PVLookup
	Cycler      *Cycler
	Baseline    *BaselineTracker
	VolumeReady *ReadyIdentityTracker
	ColdStart   *ColdStartWindow
	Recorder    record.EventRecorder // may be nil in tests
	Log         logr.Logger
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

	TriggersTotal.WithLabelValues("mount_restart").Inc()
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
	names := make([]string, len(candidates))
	for i := range candidates {
		names[i] = candidates[i].Name
	}
	logger.Info("cycling consumer pods",
		"count", len(candidates), "pods", names, "mountPod", mountPod.Name, "node", r.NodeName)
	if r.Recorder != nil {
		r.Recorder.Eventf(mountPod, corev1.EventTypeNormal, "RecycleTriggered",
			"restart detected; cycling %d consumer pod(s) on node %s", len(candidates), r.NodeName)
	}
	r.Cycler.CycleBatch(log.IntoContext(ctx, logger), candidates)
}

// HandleVolumeServerEvent is invoked by the Pod informer whenever any
// seaweedfs-volume pod transitions. Each recycler instance watches the
// cluster-wide volume pods, but only cycles candidates on its own node.
func (r *Reconciler) HandleVolumeServerEvent(ctx context.Context, volumePod *corev1.Pod) {
	logger := r.logger(ctx)

	if !podReady(volumePod) {
		return
	}
	if r.VolumeReady == nil {
		return
	}
	if !r.VolumeReady.ObserveReady(volumePod.Spec.NodeName, volumePod.UID) {
		return
	}

	TriggersTotal.WithLabelValues("volume_restart").Inc()
	logger.Info("volume server replacement detected, reconciling local recovery",
		"volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)

	mountPod, err := r.Lookup.GetLocalMountDaemon(ctx)
	if err != nil {
		logger.Error(err, "GetLocalMountDaemon failed")
		return
	}
	if mountPod != nil {
		if r.Cycler != nil && r.Cycler.Debounce != nil {
			r.Cycler.Debounce.Forget(mountPod.UID)
		}
		logger.Info("cycling local mount daemon to clear stale routing",
			"mountPod", mountPod.Name, "volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)
		if r.Recorder != nil {
			r.Recorder.Eventf(volumePod, corev1.EventTypeNormal, "RecycleTriggeredByVolumeRestart",
				"volume pod replacement on node %s detected; cycling local mount daemon %s on node %s",
				volumePod.Spec.NodeName, mountPod.Name, r.NodeName)
		}
		if err := r.Cycler.CycleOne(log.IntoContext(ctx, logger), mountPod); err != nil {
			logger.Error(err, "cycle local mount daemon failed",
				"mountPod", mountPod.Name, "volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)
		}
		return
	}

	logger.Info("local mount daemon not found; falling back to direct consumer cycling",
		"volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)

	candidates, err := r.Lookup.ListCandidates(ctx)
	if err != nil {
		logger.Error(err, "ListCandidates failed")
		return
	}
	if len(candidates) == 0 {
		logger.Info("no candidates to cycle")
		return
	}

	names := make([]string, len(candidates))
	for i := range candidates {
		names[i] = candidates[i].Name
		if r.Cycler != nil && r.Cycler.Debounce != nil {
			r.Cycler.Debounce.Forget(candidates[i].UID)
		}
	}
	logger.Info("cycling consumer pods",
		"count", len(candidates), "pods", names, "volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)
	if r.Recorder != nil {
		r.Recorder.Eventf(volumePod, corev1.EventTypeNormal, "RecycleTriggeredByVolumeRestart",
			"volume pod replacement on node %s detected; mount daemon missing, cycling %d consumer pod(s) on node %s",
			volumePod.Spec.NodeName, len(candidates), r.NodeName)
	}
	r.Cycler.CycleBatch(log.IntoContext(ctx, logger), candidates)
}

// HandleProbeFailure is invoked by the Prober for each unhealthy mountpoint.
// Not subject to the cold-start window.
func (r *Reconciler) HandleProbeFailure(ctx context.Context, mountpoint string) {
	logger := r.logger(ctx)
	TriggersTotal.WithLabelValues("probe_failure").Inc()

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
			_ = r.Cycler.CycleOne(log.IntoContext(ctx, logger), &candidates[i])
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

func podReady(pod *corev1.Pod) bool {
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady {
			return condition.Status == corev1.ConditionTrue
		}
	}
	return false
}
