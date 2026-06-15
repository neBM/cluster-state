package mountmanager

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestExportTakeoverTransfersLiveFD(t *testing.T) {
	prevPrepare := invokePrepareHotRestartFunc
	prevCancel := invokeCancelHotRestartFunc
	defer func() {
		invokePrepareHotRestartFunc = prevPrepare
		invokeCancelHotRestartFunc = prevCancel
	}()

	invokePrepareHotRestartFunc = func(context.Context, string) (PrepareHotRestartResult, error) {
		return PrepareHotRestartResult{
			Accepted: true,
			Status:   HotRestartStatus{Quiescent: true, BlockingNewHandles: true},
		}, nil
	}
	invokeCancelHotRestartFunc = func(context.Context, string) error { return nil }

	payload := filepath.Join(t.TempDir(), "fuse-device")
	if err := os.WriteFile(payload, []byte("handoff"), 0o644); err != nil {
		t.Fatalf("write payload: %v", err)
	}

	manager := NewManager(Config{})
	manager.mounts["vol-a"] = &mountEntry{
		volumeID:    "vol-a",
		targetPath:  "/var/lib/kubelet/pods/pod-a/mount",
		cacheDir:    "/var/cache/seaweedfs/vol-a",
		mountArgs:   []string{"mount", "-dir=/var/lib/kubelet/pods/pod-a/mount"},
		localSocket: "/var/lib/seaweedfs-mount/vol-a.sock",
		process: &weedMountProcess{
			dupMountFDHook: func() (*os.File, error) {
				return os.Open(payload)
			},
		},
	}

	socketPath := filepath.Join(t.TempDir(), "handoff.sock")
	fdFile, resp, err := receiveExportedFileDescriptor(socketPath, func() (*TakeoverExportResponse, error) {
		return manager.ExportTakeover(&TakeoverExportRequest{
			VolumeID:      "vol-a",
			HandoffSocket: socketPath,
		})
	})
	if err != nil {
		t.Fatalf("ExportTakeover: %v", err)
	}
	defer fdFile.Close()

	if !resp.Accepted || resp.Mount == nil {
		t.Fatalf("unexpected takeover response: %+v", resp)
	}
	data, err := io.ReadAll(fdFile)
	if err != nil {
		t.Fatalf("read transferred fd contents: %v", err)
	}
	if string(data) != "handoff" {
		t.Fatalf("transferred fd contents = %q, want %q", string(data), "handoff")
	}
}

func TestExportTakeoverRejectsBusyWorker(t *testing.T) {
	prevPrepare := invokePrepareHotRestartFunc
	defer func() { invokePrepareHotRestartFunc = prevPrepare }()

	invokePrepareHotRestartFunc = func(context.Context, string) (PrepareHotRestartResult, error) {
		return PrepareHotRestartResult{
			Accepted: false,
			Status: HotRestartStatus{
				OpenFileHandles: 1,
				Quiescent:       false,
			},
		}, nil
	}

	manager := NewManager(Config{})
	manager.mounts["vol-a"] = &mountEntry{
		volumeID:    "vol-a",
		targetPath:  "/tmp/mount",
		cacheDir:    "/tmp/cache",
		mountArgs:   []string{"mount"},
		localSocket: "/tmp/vol-a.sock",
		process:     &weedMountProcess{},
	}

	resp, err := manager.ExportTakeover(&TakeoverExportRequest{
		VolumeID:      "vol-a",
		HandoffSocket: filepath.Join(t.TempDir(), "unused.sock"),
	})
	if err != nil {
		t.Fatalf("ExportTakeover: %v", err)
	}
	if resp.Accepted {
		t.Fatalf("busy worker was unexpectedly exportable: %+v", resp)
	}
	if resp.Status == nil || resp.Status.OpenFileHandles != 1 {
		t.Fatalf("busy worker status = %+v, want open_file_handles=1", resp.Status)
	}
}

func TestFinalizeTakeoverPreservesMountOnExit(t *testing.T) {
	manager := NewManager(Config{})
	var stopCalled atomic.Bool
	process := &weedMountProcess{
		stopHook: func() error {
			stopCalled.Store(true)
			return nil
		},
	}
	manager.mounts["vol-a"] = &mountEntry{
		volumeID:    "vol-a",
		targetPath:  "/tmp/mount",
		cacheDir:    "/tmp/cache",
		mountArgs:   []string{"mount"},
		localSocket: "/tmp/vol-a.sock",
		process:     process,
	}

	if _, err := manager.FinalizeTakeover(&TakeoverFinalizeRequest{VolumeID: "vol-a"}); err != nil {
		t.Fatalf("FinalizeTakeover: %v", err)
	}
	if !stopCalled.Load() {
		t.Fatal("FinalizeTakeover did not stop the old worker")
	}
	if !process.PreserveMountOnExit() {
		t.Fatal("FinalizeTakeover did not preserve the adopted mount on old-worker exit")
	}
	if entry := manager.getMount("vol-a"); entry != nil {
		t.Fatalf("FinalizeTakeover left stale mount entry behind: %+v", entry)
	}
}

func TestCancelTakeoverClearsPreserveFlag(t *testing.T) {
	prevCancel := invokeCancelHotRestartFunc
	defer func() { invokeCancelHotRestartFunc = prevCancel }()

	var cancelCalls atomic.Int32
	invokeCancelHotRestartFunc = func(context.Context, string) error {
		cancelCalls.Add(1)
		return nil
	}

	process := &weedMountProcess{}
	process.SetPreserveMountOnExit(true)

	manager := NewManager(Config{})
	manager.mounts["vol-a"] = &mountEntry{
		volumeID:    "vol-a",
		targetPath:  "/tmp/mount",
		cacheDir:    "/tmp/cache",
		mountArgs:   []string{"mount"},
		localSocket: "/tmp/vol-a.sock",
		process:     process,
	}

	if _, err := manager.CancelTakeover(&TakeoverCancelRequest{VolumeID: "vol-a"}); err != nil {
		t.Fatalf("CancelTakeover: %v", err)
	}
	if got := cancelCalls.Load(); got != 1 {
		t.Fatalf("cancel calls = %d, want 1", got)
	}
	if process.PreserveMountOnExit() {
		t.Fatal("CancelTakeover left preserve-on-exit enabled")
	}
}

func TestTakeoverFromImportsMount(t *testing.T) {
	prevStart := startWeedMountProcessWithOptionsFunc
	defer func() { startWeedMountProcessWithOptionsFunc = prevStart }()

	var importedArgs []string
	startWeedMountProcessWithOptionsFunc = func(command string, args []string, target string, volumeID string, onExit func(), opts weedMountStartOptions) (*weedMountProcess, error) {
		importedArgs = append([]string(nil), args...)
		return &weedMountProcess{done: make(chan struct{}), mountFD: -1}, nil
	}

	socketDir := t.TempDir()
	serverDir, err := os.MkdirTemp("", "takeover-srv-")
	if err != nil {
		t.Fatalf("create server dir: %v", err)
	}
	oldServicePath := filepath.Join(serverDir, "mount.sock")
	ln, err := net.Listen("unix", oldServicePath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/takeover/inventory":
			writeJSONTest(w, TakeoverInventoryResponse{
				Mounts: []TakeoverMount{{
					VolumeID:    "vol-a",
					TargetPath:  "/tmp/mount",
					CacheDir:    "/tmp/cache",
					MountArgs:   []string{"mount", "-dir=/tmp/mount", "-localSocket=/tmp/vol-a.sock"},
					LocalSocket: filepath.Join(socketDir, "vol-a.sock"),
				}},
			})
		case "/takeover/export":
			var req TakeoverExportRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode export request: %v", err)
			}
			payload := filepath.Join(t.TempDir(), "handoff")
			if err := os.WriteFile(payload, []byte("fd"), 0o644); err != nil {
				t.Fatalf("write export payload: %v", err)
			}
			go func() {
				file, err := os.Open(payload)
				if err != nil {
					t.Errorf("open payload: %v", err)
					return
				}
				defer file.Close()
				if err := sendFileDescriptor(req.HandoffSocket, file); err != nil {
					t.Errorf("send export fd: %v", err)
				}
			}()
			writeJSONTest(w, TakeoverExportResponse{
				Accepted: true,
				Mount: &TakeoverMount{
					VolumeID:    "vol-a",
					TargetPath:  "/tmp/mount",
					CacheDir:    "/tmp/cache",
					MountArgs:   []string{"mount", "-dir=/tmp/mount", "-localSocket=/tmp/vol-a.sock"},
					LocalSocket: filepath.Join(socketDir, "vol-a.sock"),
				},
				Status: &HotRestartStatus{Quiescent: true, BlockingNewHandles: true},
			})
		case "/takeover/finalize":
			writeJSONTest(w, TakeoverFinalizeResponse{})
		default:
			t.Fatalf("unexpected takeover path: %s", r.URL.Path)
		}
	})}
	go srv.Serve(ln) //nolint:errcheck
	defer func() {
		_ = srv.Close()
		_ = os.Remove(oldServicePath)
		_ = os.RemoveAll(serverDir)
	}()

	manager := NewManager(Config{})
	if err := manager.TakeoverFrom(context.Background(), "unix://"+oldServicePath); err != nil {
		t.Fatalf("TakeoverFrom: %v", err)
	}

	entry := manager.getMount("vol-a")
	if entry == nil {
		t.Fatal("TakeoverFrom did not import the handed-off mount")
	}
	if !strings.Contains(strings.Join(importedArgs, " "), "-hotRestart.mountFd=3") {
		t.Fatalf("imported args missing hotRestart.mountFd=3: %v", importedArgs)
	}
	if !strings.Contains(strings.Join(importedArgs, " "), "-hotRestart.adoptLiveFd=true") {
		t.Fatalf("imported args missing hotRestart.adoptLiveFd=true: %v", importedArgs)
	}

	status, err := manager.StartupStatus(&StartupStatusRequest{})
	if err != nil {
		t.Fatalf("StartupStatus: %v", err)
	}
	if status.Mode != StartupModeTakeover {
		t.Fatalf("StartupStatus mode = %q, want %q", status.Mode, StartupModeTakeover)
	}
	if status.ImportedMounts != 1 {
		t.Fatalf("StartupStatus imported mounts = %d, want 1", status.ImportedMounts)
	}
}

func TestTakeoverFromCreatesMissingTargetPathForImportedMount(t *testing.T) {
	prevStart := startWeedMountProcessWithOptionsFunc
	defer func() { startWeedMountProcessWithOptionsFunc = prevStart }()

	baseDir, err := os.MkdirTemp("", "takeover-target-")
	if err != nil {
		t.Fatalf("create base dir: %v", err)
	}
	defer os.RemoveAll(baseDir)

	targetPath := filepath.Join(baseDir, "missing", "globalmount")
	localSocket := filepath.Join(baseDir, "vol-a.sock")

	startWeedMountProcessWithOptionsFunc = func(command string, args []string, target string, volumeID string, onExit func(), opts weedMountStartOptions) (*weedMountProcess, error) {
		info, err := os.Stat(target)
		if err != nil {
			t.Fatalf("import target path not prepared: %v", err)
		}
		if !info.IsDir() {
			t.Fatalf("import target path %s is not a directory", target)
		}
		return &weedMountProcess{done: make(chan struct{}), mountFD: -1}, nil
	}

	socketDir := t.TempDir()
	serverDir, err := os.MkdirTemp("", "takeover-srv-")
	if err != nil {
		t.Fatalf("create server dir: %v", err)
	}
	oldServicePath := filepath.Join(serverDir, "mount.sock")
	ln, err := net.Listen("unix", oldServicePath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/takeover/inventory":
			writeJSONTest(w, TakeoverInventoryResponse{
				Mounts: []TakeoverMount{{
					VolumeID:    "vol-a",
					TargetPath:  targetPath,
					CacheDir:    filepath.Join(t.TempDir(), "cache"),
					MountArgs:   []string{"mount", "-dir=" + targetPath, "-localSocket=" + localSocket},
					LocalSocket: filepath.Join(socketDir, "vol-a.sock"),
				}},
			})
		case "/takeover/export":
			var req TakeoverExportRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode export request: %v", err)
			}
			payload := filepath.Join(t.TempDir(), "handoff")
			if err := os.WriteFile(payload, []byte("fd"), 0o644); err != nil {
				t.Fatalf("write export payload: %v", err)
			}
			go func() {
				file, err := os.Open(payload)
				if err != nil {
					t.Errorf("open payload: %v", err)
					return
				}
				defer file.Close()
				if err := sendFileDescriptor(req.HandoffSocket, file); err != nil {
					t.Errorf("send export fd: %v", err)
				}
			}()
			writeJSONTest(w, TakeoverExportResponse{
				Accepted: true,
				Mount: &TakeoverMount{
					VolumeID:    "vol-a",
					TargetPath:  targetPath,
					CacheDir:    filepath.Join(t.TempDir(), "cache"),
					MountArgs:   []string{"mount", "-dir=" + targetPath, "-localSocket=" + localSocket},
					LocalSocket: filepath.Join(socketDir, "vol-a.sock"),
				},
				Status: &HotRestartStatus{Quiescent: true, BlockingNewHandles: true},
			})
		case "/takeover/finalize":
			writeJSONTest(w, TakeoverFinalizeResponse{})
		case "/takeover/release":
			writeJSONTest(w, TakeoverReleaseResponse{})
		default:
			t.Fatalf("unexpected takeover path: %s", r.URL.Path)
		}
	})}
	go srv.Serve(ln) //nolint:errcheck
	defer func() {
		_ = srv.Close()
		_ = os.Remove(oldServicePath)
		_ = os.RemoveAll(serverDir)
	}()

	manager := NewManager(Config{})
	if err := manager.TakeoverFrom(context.Background(), "unix://"+oldServicePath); err != nil {
		t.Fatalf("TakeoverFrom: %v", err)
	}
}

func TestTakeoverInventoryDrainsUntilRelease(t *testing.T) {
	manager := NewManager(Config{})

	if _, err := manager.TakeoverInventory(&TakeoverInventoryRequest{}); err != nil {
		t.Fatalf("TakeoverInventory: %v", err)
	}
	if _, err := manager.RefreshVolumeLocations(&RefreshVolumeLocationsRequest{}); !errors.Is(err, ErrTakeoverInProgress) {
		t.Fatalf("RefreshVolumeLocations err = %v, want %v", err, ErrTakeoverInProgress)
	}

	if _, err := manager.ReleaseTakeover(&TakeoverReleaseRequest{}); err != nil {
		t.Fatalf("ReleaseTakeover: %v", err)
	}
	if _, err := manager.RefreshVolumeLocations(&RefreshVolumeLocationsRequest{}); err != nil {
		t.Fatalf("RefreshVolumeLocations after release: %v", err)
	}
}

func TestTakeoverFromReturnsUnsupportedForLegacyManager(t *testing.T) {
	oldServicePath, closeOld := newUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/takeover/inventory" {
			t.Fatalf("unexpected takeover path: %s", r.URL.Path)
		}
		http.NotFound(w, r)
	}))
	defer closeOld()

	manager := NewManager(Config{})
	err := manager.TakeoverFrom(context.Background(), "unix://"+oldServicePath)
	if !errors.Is(err, ErrTakeoverUnsupported) {
		t.Fatalf("TakeoverFrom err = %v, want %v", err, ErrTakeoverUnsupported)
	}
}

func writeJSONTest(w http.ResponseWriter, data any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(data); err != nil {
		panic(err)
	}
}
