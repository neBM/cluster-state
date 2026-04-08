package recycler

import (
	"context"
	"fmt"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
)

// Evictor is the minimal API the cycler needs, separated from the real k8s
// client so tests can substitute fakes. Production impl is KubeEvictor below.
type Evictor interface {
	Evict(ctx context.Context, pod *corev1.Pod) error
	ForceDelete(ctx context.Context, pod *corev1.Pod) error
}

// Cycler orchestrates eviction-first, fallback-to-force-delete cycling of a
// single pod, honoring a debounce map.
type Cycler struct {
	Evictor          Evictor
	Debounce         *Debouncer
	Stagger          time.Duration
	EvictionRetry    time.Duration
	EvictionDeadline time.Duration
}

// CycleOne cycles a single candidate pod. Idempotent against the debounce
// map: consecutive calls with the same pod UID within the debounce window
// are no-ops.
func (c *Cycler) CycleOne(ctx context.Context, pod *corev1.Pod) error {
	if c.Debounce.Skip(pod.UID) {
		CyclesTotal.WithLabelValues("skipped_debounce").Inc()
		return nil
	}

	deadline := time.Now().Add(c.EvictionDeadline)
	for {
		err := c.Evictor.Evict(ctx, pod)
		if err == nil {
			c.Debounce.Mark(pod.UID)
			CyclesTotal.WithLabelValues("evicted").Inc()
			return nil
		}
		if !apierrors.IsTooManyRequests(err) {
			CyclesTotal.WithLabelValues("error").Inc()
			return fmt.Errorf("evict %s/%s: %w", pod.Namespace, pod.Name, err)
		}
		EvictionBlockedTotal.WithLabelValues("pdb").Inc()
		if time.Now().After(deadline) {
			if derr := c.Evictor.ForceDelete(ctx, pod); derr != nil {
				CyclesTotal.WithLabelValues("error").Inc()
				return fmt.Errorf("force-delete %s/%s: %w", pod.Namespace, pod.Name, derr)
			}
			c.Debounce.Mark(pod.UID)
			CyclesTotal.WithLabelValues("forced").Inc()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(c.EvictionRetry):
		}
	}
}

// CycleBatch cycles all pods in candidates, sleeping Stagger between each.
func (c *Cycler) CycleBatch(ctx context.Context, candidates []corev1.Pod) {
	for i := range candidates {
		_ = c.CycleOne(ctx, &candidates[i])
		if i < len(candidates)-1 && c.Stagger > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(c.Stagger):
			}
		}
	}
}

// Debouncer tracks pod UIDs that have been cycled recently so we skip them.
type Debouncer struct {
	mu  sync.Mutex
	ttl time.Duration
	m   map[types.UID]time.Time
}

func NewDebouncer(ttl time.Duration) *Debouncer {
	return &Debouncer{ttl: ttl, m: map[types.UID]time.Time{}}
}

func (d *Debouncer) Skip(uid types.UID) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	t, ok := d.m[uid]
	if !ok {
		return false
	}
	if time.Since(t) >= d.ttl {
		delete(d.m, uid)
		return false
	}
	return true
}

func (d *Debouncer) Mark(uid types.UID) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.m[uid] = time.Now()
}

// KubeEvictor is the production implementation of Evictor backed by client-go.
type KubeEvictor struct {
	Clientset kubernetes.Interface
}

func (k *KubeEvictor) Evict(ctx context.Context, pod *corev1.Pod) error {
	return k.Clientset.PolicyV1().Evictions(pod.Namespace).Evict(ctx, &policyv1.Eviction{
		ObjectMeta: metav1.ObjectMeta{Name: pod.Name, Namespace: pod.Namespace},
	})
}

func (k *KubeEvictor) ForceDelete(ctx context.Context, pod *corev1.Pod) error {
	zero := int64(0)
	return k.Clientset.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{
		GracePeriodSeconds: &zero,
	})
}
