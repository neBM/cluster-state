package recycler

import (
	"testing"
	"time"
)

func TestBaselineTracker_FirstObservationNeverTriggers(t *testing.T) {
	bt := NewBaselineTracker()
	if bt.ObserveRestart("uid1", 0) {
		t.Fatal("first observation must not trigger")
	}
}

func TestBaselineTracker_RestartCountBumpTriggers(t *testing.T) {
	bt := NewBaselineTracker()
	bt.ObserveRestart("uid1", 0)
	if !bt.ObserveRestart("uid1", 1) {
		t.Fatal("incremented restart count must trigger")
	}
}

func TestBaselineTracker_UIDChangeTriggers(t *testing.T) {
	bt := NewBaselineTracker()
	bt.ObserveRestart("uid1", 3)
	if !bt.ObserveRestart("uid2", 0) {
		t.Fatal("new UID must trigger")
	}
}

func TestBaselineTracker_SameStateDoesNotTrigger(t *testing.T) {
	bt := NewBaselineTracker()
	bt.ObserveRestart("uid1", 5)
	if bt.ObserveRestart("uid1", 5) {
		t.Fatal("no-change observation must not trigger")
	}
}

func TestColdStartWindow_SuppressesPathADuringGrace(t *testing.T) {
	w := NewColdStartWindow(60 * time.Second)
	if !w.Suppressed(w.startedAt.Add(30 * time.Second)) {
		t.Fatal("should suppress within grace window")
	}
	if w.Suppressed(w.startedAt.Add(61 * time.Second)) {
		t.Fatal("should not suppress after grace window")
	}
}
