package recycler

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountmanager"
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
	Mounts      mountServiceRefresher
	Baseline    *BaselineTracker
	VolumeReady *ReadyIdentityTracker
	ColdStart   *ColdStartWindow
	Recorder    record.EventRecorder // may be nil in tests
	Log         logr.Logger
}

type mountServiceRefresher interface {
	RefreshVolumeLocations(ctx context.Context) (*mountmanager.RefreshVolumeLocationsResponse, error)
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

	VolumeRefreshesTotal.WithLabelValues("started").Inc()
	if r.Recorder != nil {
		r.Recorder.Eventf(volumePod, corev1.EventTypeNormal, "VolumeRefreshStarted",
			"volume pod replacement on node %s detected; refreshing local mount routing on node %s",
			volumePod.Spec.NodeName, r.NodeName)
	}
	if r.Mounts == nil {
		VolumeRefreshesTotal.WithLabelValues("failed").Inc()
		logger.Error(fmt.Errorf("mount refresh client not configured"), "volume location refresh unavailable",
			"volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)
		if r.Recorder != nil {
			r.Recorder.Eventf(volumePod, corev1.EventTypeWarning, "VolumeRefreshFailed",
				"volume pod replacement on node %s detected, but the local mount refresh client is not configured on node %s",
				volumePod.Spec.NodeName, r.NodeName)
		}
		return
	}

	resp, err := r.Mounts.RefreshVolumeLocations(log.IntoContext(ctx, logger))
	if err != nil {
		VolumeRefreshesTotal.WithLabelValues("failed").Inc()
		logger.Error(err, "volume location refresh failed",
			"volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName)
		if r.Recorder != nil {
			r.Recorder.Eventf(volumePod, corev1.EventTypeWarning, "VolumeRefreshFailed",
				"volume pod replacement on node %s detected; local mount refresh failed on node %s: %v",
				volumePod.Spec.NodeName, r.NodeName, err)
		}
		return
	}
	if resp == nil {
		resp = &mountmanager.RefreshVolumeLocationsResponse{}
	}
	if len(resp.Failed) > 0 {
		VolumeRefreshesTotal.WithLabelValues("failed").Inc()
		logger.Error(fmt.Errorf("one or more mount refreshes failed"), "volume location refresh reported failures",
			"volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName,
			"refreshed", resp.Refreshed, "failed", resp.Failed)
		if r.Recorder != nil {
			r.Recorder.Eventf(volumePod, corev1.EventTypeWarning, "VolumeRefreshFailed",
				"volume pod replacement on node %s detected; %d local mount refresh(es) failed on node %s",
				volumePod.Spec.NodeName, len(resp.Failed), r.NodeName)
		}
		return
	}
	VolumeRefreshesTotal.WithLabelValues("succeeded").Inc()
	logger.Info("refreshed local mount routing after volume replacement",
		"volumePod", volumePod.Name, "volumeNode", volumePod.Spec.NodeName, "node", r.NodeName,
		"refreshedCount", len(resp.Refreshed), "refreshed", resp.Refreshed)
	if r.Recorder != nil {
		r.Recorder.Eventf(volumePod, corev1.EventTypeNormal, "VolumeRefreshSucceeded",
			"volume pod replacement on node %s detected; refreshed %d local mount routing cache(s) on node %s",
			volumePod.Spec.NodeName, len(resp.Refreshed), r.NodeName)
	}
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
