package recycler

import (
	"context"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
)

// fakeEvictor records eviction attempts and can be scripted to return errors.
type fakeEvictor struct {
	attempts  []types.NamespacedName
	errorFunc func(attempt int) error
	deletes   []types.NamespacedName
}

func (f *fakeEvictor) Evict(ctx context.Context, pod *corev1.Pod) error {
	f.attempts = append(f.attempts, types.NamespacedName{Namespace: pod.Namespace, Name: pod.Name})
	if f.errorFunc != nil {
		return f.errorFunc(len(f.attempts))
	}
	return nil
}

func (f *fakeEvictor) ForceDelete(ctx context.Context, pod *corev1.Pod) error {
	f.deletes = append(f.deletes, types.NamespacedName{Namespace: pod.Namespace, Name: pod.Name})
	return nil
}

func TestCycler_EvictsSuccess(t *testing.T) {
	ev := &fakeEvictor{}
	c := &Cycler{
		Evictor:          ev,
		Stagger:          0,
		Debounce:         NewDebouncer(time.Minute),
		EvictionRetry:    10 * time.Millisecond,
		EvictionDeadline: 100 * time.Millisecond,
	}
	p := pod("app1", "nyx", "d1")
	if err := c.CycleOne(context.Background(), p); err != nil {
		t.Fatalf("CycleOne: %v", err)
	}
	if len(ev.attempts) != 1 {
		t.Fatalf("want 1 attempt, got %d", len(ev.attempts))
	}
	if len(ev.deletes) != 0 {
		t.Fatalf("want no force-deletes, got %d", len(ev.deletes))
	}
}

func TestCycler_PDBFallbackAfterDeadline(t *testing.T) {
	ev := &fakeEvictor{
		errorFunc: func(attempt int) error {
			return apierrors.NewTooManyRequests("pdb", 0)
		},
	}
	c := &Cycler{
		Evictor:          ev,
		Stagger:          0,
		Debounce:         NewDebouncer(time.Minute),
		EvictionRetry:    10 * time.Millisecond,
		EvictionDeadline: 50 * time.Millisecond,
	}
	p := pod("app1", "nyx", "d1")
	if err := c.CycleOne(context.Background(), p); err != nil {
		t.Fatalf("CycleOne: %v", err)
	}
	if len(ev.attempts) < 2 {
		t.Fatalf("want >= 2 eviction attempts, got %d", len(ev.attempts))
	}
	if len(ev.deletes) != 1 {
		t.Fatalf("want 1 force-delete, got %d", len(ev.deletes))
	}
}

func TestCycler_Debounce(t *testing.T) {
	ev := &fakeEvictor{}
	d := NewDebouncer(time.Minute)
	c := &Cycler{
		Evictor:          ev,
		Stagger:          0,
		Debounce:         d,
		EvictionRetry:    10 * time.Millisecond,
		EvictionDeadline: 100 * time.Millisecond,
	}
	p := pod("app1", "nyx", "d1")
	_ = c.CycleOne(context.Background(), p)
	_ = c.CycleOne(context.Background(), p)
	if len(ev.attempts) != 1 {
		t.Fatalf("want 1 attempt due to debounce, got %d", len(ev.attempts))
	}
}
