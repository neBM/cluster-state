package recycler

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestReconciler_CycleAllCandidatesOnRestart(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-2"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
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

func TestReconciler_ColdStartSuppressesPathA(t *testing.T) {
	mountPod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "seaweedfs-mount-nyx", Namespace: "default", UID: "mp-uid-3"},
		Spec:       corev1.PodSpec{NodeName: "nyx"},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
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
