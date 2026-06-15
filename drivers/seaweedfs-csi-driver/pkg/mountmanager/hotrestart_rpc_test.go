package mountmanager

import (
	"context"
	"testing"
)

func TestHotRestartRPCs(t *testing.T) {
	socketPath, server, closeFn := newUnixMountGRPCServer(t)
	defer closeFn()

	server.hotRestartStatus = HotRestartStatus{
		OpenFileHandles:      2,
		OpenDirectoryHandles: 1,
		PendingAsyncFlushes:  3,
		Quiescent:            false,
	}
	server.prepareHotRestart = PrepareHotRestartResult{
		Accepted: false,
		Status: HotRestartStatus{
			OpenFileHandles:      2,
			OpenDirectoryHandles: 1,
			PendingAsyncFlushes:  3,
			Quiescent:            false,
			BlockingNewHandles:   false,
		},
	}

	status, err := invokeHotRestartStatus(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("HotRestartStatus: %v", err)
	}
	if status != server.hotRestartStatus {
		t.Fatalf("hot restart status = %+v, want %+v", status, server.hotRestartStatus)
	}

	prepare, err := invokePrepareHotRestart(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("PrepareHotRestart: %v", err)
	}
	if prepare != server.prepareHotRestart {
		t.Fatalf("prepare result = %+v, want %+v", prepare, server.prepareHotRestart)
	}

	if err := invokeCancelHotRestart(context.Background(), socketPath); err != nil {
		t.Fatalf("CancelHotRestart: %v", err)
	}
	if got := server.cancelCalls.Load(); got != 1 {
		t.Fatalf("cancel calls = %d, want 1", got)
	}
}
