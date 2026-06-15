package recycler

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountmanager"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

type fakeMountService struct {
	calls         int
	response      *mountmanager.RefreshVolumeLocationsResponse
	err           error
	startupCalls  int
	startupStatus *mountmanager.StartupStatusResponse
	startupErr    error
}

func (f *fakeMountService) RefreshVolumeLocations(ctx context.Context) (*mountmanager.RefreshVolumeLocationsResponse, error) {
	f.calls++
	if f.response != nil {
		return f.response, f.err
	}
	return &mountmanager.RefreshVolumeLocationsResponse{}, f.err
}

func (f *fakeMountService) StartupStatus(ctx context.Context) (*mountmanager.StartupStatusResponse, error) {
	f.startupCalls++
	if f.startupStatus != nil {
		return f.startupStatus, f.startupErr
	}
	return &mountmanager.StartupStatusResponse{Mode: mountmanager.StartupModeFresh}, f.startupErr
}

func TestReconciler_CycleAllCandidatesOnRestart(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-2"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 0, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}

	c := newFakeClient(
		mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
		pod("app2", "nyx", "app2-data"), pvc("app2-data", "pv-2"), pv("pv-2", csiDriverName),
	)

	ev := &fakeEvictor{}
	r := &Reconciler{
		Client:   c,
		NodeName: "nyx",
		Lookup:   &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler: &Cycler{
			Evictor:          ev,
			Debounce:         NewDebouncer(time.Minute),
			EvictionRetry:    1 * time.Millisecond,
			EvictionDeadline: 10 * time.Millisecond,
		},
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	// First observation — records baseline, no cycling.
	r.HandleMountDaemonEvent(context.Background(), mountPod)
	if len(ev.attempts) != 0 {
		t.Fatalf("first observation should not cycle: got %d attempts", len(ev.attempts))
	}

	// Simulate restart.
	mountPod.Status.ContainerStatuses[0].RestartCount = 1
	r.HandleMountDaemonEvent(context.Background(), mountPod)

	if len(ev.attempts) != 2 {
		t.Fatalf("want 2 eviction attempts after restart, got %d", len(ev.attempts))
	}
}

func TestReconciler_DoesNotCycleUnreadyReplacementUntilReady(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx-a", Namespace: "default", UID: "mp-uid-old"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 0, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}

	replacement := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx-b", Namespace: "default", UID: "mp-uid-new"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionFalse},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 0, Ready: false},
			},
		},
	}
	replacement.Labels = map[string]string{"component": "seaweedfs-mount"}

	c := newFakeClient(
		mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)
	ev := &fakeEvictor{}
	r := &Reconciler{
		Client:   c,
		NodeName: "nyx",
		Lookup:   &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler: &Cycler{
			Evictor:          ev,
			Debounce:         NewDebouncer(time.Minute),
			EvictionRetry:    1 * time.Millisecond,
			EvictionDeadline: 10 * time.Millisecond,
		},
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleMountDaemonEvent(context.Background(), mountPod)
	r.HandleMountDaemonEvent(context.Background(), replacement)
	if len(ev.attempts) != 0 {
		t.Fatalf("unready replacement should not cycle consumers, got %d attempts", len(ev.attempts))
	}

	replacement.Status.Conditions[0].Status = corev1.ConditionTrue
	replacement.Status.ContainerStatuses[0].Ready = true
	r.HandleMountDaemonEvent(context.Background(), replacement)
	if len(ev.attempts) != 1 {
		t.Fatalf("ready replacement should cycle consumers once, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_SuppressesCleanTakeoverReplacement(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-4"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 0, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}

	c := newFakeClient(
		mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
		pod("app2", "nyx", "app2-data"), pvc("app2-data", "pv-2"), pv("pv-2", csiDriverName),
	)
	ev := &fakeEvictor{}
	mountService := &fakeMountService{
		startupStatus: &mountmanager.StartupStatusResponse{
			Mode:           mountmanager.StartupModeTakeover,
			ImportedMounts: 2,
		},
	}
	r := &Reconciler{
		Client:   c,
		NodeName: "nyx",
		Lookup:   &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler: &Cycler{
			Evictor:          ev,
			Debounce:         NewDebouncer(time.Minute),
			EvictionRetry:    1 * time.Millisecond,
			EvictionDeadline: 10 * time.Millisecond,
		},
		Mounts:    mountService,
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleMountDaemonEvent(context.Background(), mountPod)
	if len(ev.attempts) != 0 {
		t.Fatalf("first observation should not cycle: got %d attempts", len(ev.attempts))
	}

	replacement := mountPod.DeepCopy()
	replacement.Name = "seaweedfs-mount-nyx-replacement"
	replacement.UID = "mp-uid-5"
	r.HandleMountDaemonEvent(context.Background(), replacement)

	if len(ev.attempts) != 0 {
		t.Fatalf("clean takeover should suppress consumer recycling, got %d attempts", len(ev.attempts))
	}
	if mountService.startupCalls != 1 {
		t.Fatalf("expected one startup-status probe, got %d", mountService.startupCalls)
	}
}

func TestReconciler_FailsClosedWhenStartupStatusProbeFails(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-6"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 0, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}

	c := newFakeClient(
		mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)
	ev := &fakeEvictor{}
	mountService := &fakeMountService{startupErr: context.DeadlineExceeded}
	r := &Reconciler{
		Client:   c,
		NodeName: "nyx",
		Lookup:   &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler: &Cycler{
			Evictor:          ev,
			Debounce:         NewDebouncer(time.Minute),
			EvictionRetry:    1 * time.Millisecond,
			EvictionDeadline: 10 * time.Millisecond,
		},
		Mounts:    mountService,
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleMountDaemonEvent(context.Background(), mountPod)
	replacement := mountPod.DeepCopy()
	replacement.Name = "seaweedfs-mount-nyx-replacement"
	replacement.UID = "mp-uid-7"
	r.HandleMountDaemonEvent(context.Background(), replacement)

	if len(ev.attempts) != 1 {
		t.Fatalf("startup-status probe failure should fail closed and cycle, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_LogsCyclingWithCandidateNames(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-log-1"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
			ContainerStatuses: []corev1.ContainerStatus{{Name: "seaweedfs-mount", RestartCount: 1, Ready: true}},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}
	c := newFakeClient(mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
		pod("app2", "nyx", "app2-data"), pvc("app2-data", "pv-2"), pv("pv-2", csiDriverName),
	)

	lg, snapshot := newCaptureLogger()
	bt := NewBaselineTracker()
	bt.ObserveRestart(mountPod.UID, 0) // seed baseline so next observation triggers

	r := &Reconciler{
		Client:    c,
		NodeName:  "nyx",
		Lookup:    &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler:    &Cycler{Evictor: &fakeEvictor{}, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Baseline:  bt,
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
		Log:       lg,
	}
	r.HandleMountDaemonEvent(context.Background(), mountPod)

	var cycling string
	for _, m := range snapshot() {
		if strings.Contains(m, "cycling consumer pods") {
			cycling = m
			break
		}
	}
	if cycling == "" {
		t.Fatalf("expected a 'cycling consumer pods' log line, got: %v", snapshot())
	}
	if !strings.Contains(cycling, "count=2") {
		t.Errorf("expected count=2 in log line, got: %s", cycling)
	}
	if !strings.Contains(cycling, "app1") || !strings.Contains(cycling, "app2") {
		t.Errorf("expected pod names in log line, got: %s", cycling)
	}
}

func TestReconciler_ColdStartSuppressesPathA(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-3"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "seaweedfs-mount", RestartCount: 5, Ready: true},
			},
		},
	}
	mountPod.Labels = map[string]string{"component": "seaweedfs-mount"}
	c := newFakeClient(mountPod,
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)
	ev := &fakeEvictor{}
	bt := NewBaselineTracker()
	bt.ObserveRestart("mp-uid-3", 5)
	r := &Reconciler{
		Client:    c,
		NodeName:  "nyx",
		Lookup:    &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler:    &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Baseline:  bt,
		ColdStart: &ColdStartWindow{startedAt: time.Now(), grace: time.Minute},
	}
	mountPod.Status.ContainerStatuses[0].RestartCount = 6
	r.HandleMountDaemonEvent(context.Background(), mountPod)
	if len(ev.attempts) != 0 {
		t.Fatalf("cold-start window should suppress Path A, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_ColdStartSuppressesProbeFailure(t *testing.T) {
	c := newFakeClient(
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)
	ev := &fakeEvictor{}
	r := &Reconciler{
		Client:    c,
		NodeName:  "nyx",
		Lookup:    &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler:    &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now(), grace: time.Minute},
	}

	r.HandleProbeFailure(context.Background(), "/var/lib/kubelet/pods/uid-app1/volumes/kubernetes.io~csi/app1-data/mount")

	if len(ev.attempts) != 0 {
		t.Fatalf("cold-start window should suppress probe-triggered cycling, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_ProbeFailureCyclesAfterColdStart(t *testing.T) {
	c := newFakeClient(
		pod("app1", "nyx", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)
	ev := &fakeEvictor{}
	r := &Reconciler{
		Client:    c,
		NodeName:  "nyx",
		Lookup:    &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName},
		Cycler:    &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Baseline:  NewBaselineTracker(),
		ColdStart: &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleProbeFailure(context.Background(), "/var/lib/kubelet/pods/uid-app1/volumes/kubernetes.io~csi/app1-data/mount")

	if len(ev.attempts) != 1 {
		t.Fatalf("probe-triggered cycling should still evict after cold start, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_RefreshesLocalMountsOnReadyVolumeReplacement(t *testing.T) {
	volumePod := readyVolumePod("seaweedfs-volume-nyx-a", "nyx", "vol-uid-1")
	c := newFakeClient(
		volumePod,
		pod("app1", "hestia", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
		pod("app2", "hestia", "app2-data"), pvc("app2-data", "pv-2"), pv("pv-2", csiDriverName),
	)

	ev := &fakeEvictor{}
	mountService := &fakeMountService{}
	r := &Reconciler{
		Client:      c,
		NodeName:    "hestia",
		Lookup:      &PVLookup{Client: c, NodeName: "hestia", Driver: csiDriverName},
		Cycler:      &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Mounts:      mountService,
		Baseline:    NewBaselineTracker(),
		VolumeReady: NewReadyIdentityTracker(),
		ColdStart:   &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleVolumeServerEvent(context.Background(), volumePod)
	if len(ev.attempts) != 0 {
		t.Fatalf("first ready observation should not cycle: got %d attempts", len(ev.attempts))
	}

	replacement := readyVolumePod("seaweedfs-volume-nyx-b", "nyx", "vol-uid-2")
	r.HandleVolumeServerEvent(context.Background(), replacement)

	if mountService.calls != 1 {
		t.Fatalf("want 1 refresh call after ready replacement, got %d", mountService.calls)
	}
	if len(ev.attempts) != 0 {
		t.Fatalf("volume refresh path should not evict pods, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_VolumeReplacementStopsOnRefreshFailure(t *testing.T) {
	volumePod := readyVolumePod("seaweedfs-volume-nyx-a", "nyx", "vol-uid-1")
	c := newFakeClient(
		volumePod,
		pod("app1", "hestia", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
		pod("app2", "hestia", "app2-data"), pvc("app2-data", "pv-2"), pv("pv-2", csiDriverName),
	)

	ev := &fakeEvictor{}
	mountService := &fakeMountService{
		response: &mountmanager.RefreshVolumeLocationsResponse{
			Failed: []mountmanager.RefreshVolumeLocationsFailure{
				{VolumeID: "vol-a", Error: "dial unix:///missing.sock: connect: no such file"},
			},
		},
	}

	r := &Reconciler{
		Client:      c,
		NodeName:    "hestia",
		Lookup:      &PVLookup{Client: c, NodeName: "hestia", Driver: csiDriverName},
		Cycler:      &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Mounts:      mountService,
		Baseline:    NewBaselineTracker(),
		VolumeReady: NewReadyIdentityTracker(),
		ColdStart:   &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleVolumeServerEvent(context.Background(), volumePod)
	r.HandleVolumeServerEvent(context.Background(), readyVolumePod("seaweedfs-volume-nyx-b", "nyx", "vol-uid-2"))

	if mountService.calls != 1 {
		t.Fatalf("want 1 refresh call, got %d", mountService.calls)
	}
	if len(ev.attempts) != 0 {
		t.Fatalf("refresh failure should not evict consumers automatically, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_VolumeReplacementTreatsRefreshErrorAsFailure(t *testing.T) {
	volumePod := readyVolumePod("seaweedfs-volume-nyx-a", "nyx", "vol-uid-1")
	c := newFakeClient(
		volumePod,
		pod("app1", "hestia", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)

	ev := &fakeEvictor{}
	mountService := &fakeMountService{err: context.DeadlineExceeded}

	r := &Reconciler{
		Client:      c,
		NodeName:    "hestia",
		Lookup:      &PVLookup{Client: c, NodeName: "hestia", Driver: csiDriverName},
		Cycler:      &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Mounts:      mountService,
		Baseline:    NewBaselineTracker(),
		VolumeReady: NewReadyIdentityTracker(),
		ColdStart:   &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleVolumeServerEvent(context.Background(), volumePod)
	r.HandleVolumeServerEvent(context.Background(), readyVolumePod("seaweedfs-volume-nyx-b", "nyx", "vol-uid-2"))

	if mountService.calls != 1 {
		t.Fatalf("want 1 refresh call, got %d", mountService.calls)
	}
	if len(ev.attempts) != 0 {
		t.Fatalf("refresh error should not evict consumers automatically, got %d attempts", len(ev.attempts))
	}
}

func TestReconciler_IgnoresUnreadyVolumeReplacement(t *testing.T) {
	volumePod := readyVolumePod("seaweedfs-volume-nyx-a", "nyx", "vol-uid-1")
	c := newFakeClient(
		volumePod,
		pod("app1", "hestia", "app1-data"), pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName),
	)

	ev := &fakeEvictor{}
	mountService := &fakeMountService{}

	r := &Reconciler{
		Client:      c,
		NodeName:    "hestia",
		Lookup:      &PVLookup{Client: c, NodeName: "hestia", Driver: csiDriverName},
		Cycler:      &Cycler{Evictor: ev, Debounce: NewDebouncer(time.Minute), EvictionRetry: 1 * time.Millisecond, EvictionDeadline: 10 * time.Millisecond},
		Mounts:      mountService,
		Baseline:    NewBaselineTracker(),
		VolumeReady: NewReadyIdentityTracker(),
		ColdStart:   &ColdStartWindow{startedAt: time.Now().Add(-10 * time.Minute), grace: time.Minute},
	}

	r.HandleVolumeServerEvent(context.Background(), volumePod)
	unreadyReplacement := readyVolumePod("seaweedfs-volume-nyx-b", "nyx", "vol-uid-2")
	unreadyReplacement.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionFalse}}
	r.HandleVolumeServerEvent(context.Background(), unreadyReplacement)

	if mountService.calls != 0 {
		t.Fatalf("unready replacement should not refresh mounts, got %d calls", mountService.calls)
	}
	if len(ev.attempts) != 0 {
		t.Fatalf("unready replacement should not cycle, got %d attempts", len(ev.attempts))
	}
}

func readyVolumePod(name, node, uid string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "default",
			UID:       types.UID(uid),
			Labels:    map[string]string{"component": "volume"},
		},
		Spec: corev1.PodSpec{NodeName: node},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
		},
	}
}
