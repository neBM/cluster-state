package recycler

import (
	"sync"
	"time"

	"k8s.io/apimachinery/pkg/types"
)

// BaselineTracker remembers the most recently observed {UID, RestartCount}
// tuple per seaweedfs-mount pod so we can detect the NEXT restart without
// false-firing on the FIRST observation after recycler startup.
type BaselineTracker struct {
	mu       sync.Mutex
	baseline map[types.UID]int32
}

func NewBaselineTracker() *BaselineTracker {
	return &BaselineTracker{baseline: map[types.UID]int32{}}
}

// ObserveRestart records (uid, restartCount) and returns true iff this
// observation represents a restart relative to the stored baseline.
//
// Trigger semantics:
//   - Empty tracker (no UIDs ever seen): first observation records baseline,
//     returns false.
//   - Known UID with incremented restartCount: returns true.
//   - Known UID with same or lower restartCount: returns false.
//   - New UID appearing in a non-empty tracker: returns true (mount-daemon
//     pod was recreated).
func (b *BaselineTracker) ObserveRestart(uid types.UID, restartCount int32) bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	prev, seen := b.baseline[uid]
	trackerWasEmpty := len(b.baseline) == 0
	b.baseline[uid] = restartCount

	if seen {
		return restartCount > prev
	}
	// New UID: trigger iff the tracker was already tracking other UIDs.
	return !trackerWasEmpty
}

// Forget removes a UID from the baseline map (call on pod delete events).
func (b *BaselineTracker) Forget(uid types.UID) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.baseline, uid)
}

// ColdStartWindow suppresses Path A triggers for the first `grace` duration
// after recycler startup. Path B (the prober) is unaffected.
type ColdStartWindow struct {
	startedAt time.Time
	grace     time.Duration
}

func NewColdStartWindow(grace time.Duration) *ColdStartWindow {
	return &ColdStartWindow{startedAt: time.Now(), grace: grace}
}

// Suppressed reports whether Path A should be suppressed at time `now`.
func (w *ColdStartWindow) Suppressed(now time.Time) bool {
	return now.Before(w.startedAt.Add(w.grace))
}
