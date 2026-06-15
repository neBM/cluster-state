package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountmanager"
	"github.com/seaweedfs/seaweedfs/weed/glog"
)

var (
	endpoint          = flag.String("endpoint", "unix:///tmp/seaweedfs-mount.sock", "endpoint the mount service listens on")
	weedBinary        = flag.String("weedBinary", mountmanager.DefaultWeedBinary, "path to the weed binary")
	healthBindAddress = flag.String("health-bind-address", ":9807", "TCP address for health and readiness probes")
)

func main() {
	flag.Parse()

	scheme, address, err := mountmanager.ParseEndpoint(*endpoint)
	if err != nil {
		glog.Fatalf("invalid endpoint: %v", err)
	}
	if scheme != "unix" {
		glog.Fatalf("unsupported endpoint scheme: %s", scheme)
	}

	readiness := newReadinessGate()
	healthServer, err := startHealthServer(*healthBindAddress, readiness)
	if err != nil {
		glog.Fatalf("starting health server: %v", err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		shutdownHealthServer(shutdownCtx, healthServer)
	}()

	probeCtx, probeCancel := context.WithTimeout(context.Background(), 2*time.Second)
	liveService, probeErr := mountmanager.HasLiveService(probeCtx, *endpoint)
	probeCancel()
	if probeErr != nil {
		glog.Fatalf("probing existing mount service: %v", probeErr)
	}
	if liveService {
		manager := mountmanager.NewManager(mountmanager.Config{WeedBinary: *weedBinary})
		if err := manager.TakeoverFrom(context.Background(), *endpoint); err != nil {
			if errors.Is(err, mountmanager.ErrTakeoverUnsupported) {
				glog.Warningf("legacy mount service at %s does not support live takeover, starting bridge mode", *endpoint)
				manager.SetStartupStatus(mountmanager.StartupStatusResponse{
					Mode: mountmanager.StartupModeLegacyBridge,
				})
				legacyCleanupCtx, legacyCleanupCancel := context.WithTimeout(context.Background(), 2*time.Minute)
				defer legacyCleanupCancel()
				go mountmanager.WatchStaleMounts(legacyCleanupCtx, filepath.Dir(address), time.Second)

				if err := os.Remove(address); err != nil && !errors.Is(err, os.ErrNotExist) {
					glog.Fatalf("removing live mount service socket before rebinding: %v", err)
				}

				startMountService(address, manager, readiness)
				return
			}
			glog.Fatalf("take over live mount service at %s: %v", *endpoint, err)
		}

		if err := os.Remove(address); err != nil && !errors.Is(err, os.ErrNotExist) {
			glog.Fatalf("removing live mount service socket before rebinding: %v", err)
		}

		startMountService(address, manager, readiness)
		return
	}

	// Recover from prior mount service instance that died holding live FUSE
	// mounts. This lazy-unmounts any stale fuse.seaweedfs entries so kubelet's
	// reconciler re-triggers NodeStage/NodePublishVolume via the CSI plugin's
	// existing self-heal path. Must run before the HTTP listener opens so
	// cleanup finishes before the first /mount call arrives.
	recoveredStaleMounts := mountmanager.ReconcileStaleMounts(filepath.Dir(address))

	if err := os.Remove(address); err != nil && !errors.Is(err, os.ErrNotExist) {
		glog.Fatalf("removing existing socket: %v", err)
	}

	manager := mountmanager.NewManager(mountmanager.Config{WeedBinary: *weedBinary})
	if recoveredStaleMounts > 0 {
		manager.SetStartupStatus(mountmanager.StartupStatusResponse{
			Mode:                 mountmanager.StartupModeCrashRecovery,
			RecoveredStaleMounts: recoveredStaleMounts,
		})
	}

	startMountService(address, manager, readiness)
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		glog.Errorf("writing response failed: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, mountmanager.ErrorResponse{Error: message})
}

func startMountService(address string, manager *mountmanager.Manager, readiness *readinessGate) {
	listener, err := listenOwnedUnixSocket(address)
	if err != nil {
		glog.Fatalf("failed to listen on %s: %v", address, err)
	}
	defer func() {
		_ = listener.Close()
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/mount", makePostHandler(manager.Mount))
	mux.HandleFunc("/unmount", makePostHandler(manager.Unmount))
	mux.HandleFunc("/refresh-volume-locations", makePostHandler(manager.RefreshVolumeLocations))
	mux.HandleFunc("/startup-status", makePostHandler(manager.StartupStatus))
	mux.HandleFunc("/takeover/inventory", makePostHandler(manager.TakeoverInventory))
	mux.HandleFunc("/takeover/export", makePostHandler(manager.ExportTakeover))
	mux.HandleFunc("/takeover/finalize", makePostHandler(manager.FinalizeTakeover))
	mux.HandleFunc("/takeover/cancel", makePostHandler(manager.CancelTakeover))
	mux.HandleFunc("/takeover/release", makePostHandler(manager.ReleaseTakeover))

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	server := &http.Server{Handler: mux}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			glog.Fatalf("server error: %v", err)
		}
	}()
	if readiness != nil {
		readiness.SetReady(true)
	}

	glog.Infof("mount service listening on unix://%s", address)

	<-ctx.Done()
	if readiness != nil {
		readiness.SetReady(false)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		glog.Errorf("server shutdown error: %v", err)
	}

	glog.Infof("mount service stopped")
}

// makePostHandler creates a generic HTTP POST handler that decodes JSON request,
// calls the manager function, and encodes the JSON response.
func makePostHandler[Req any, Resp any](managerFunc func(*Req) (*Resp, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}

		var req Req
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request: "+err.Error())
			return
		}

		resp, err := managerFunc(&req)
		if err != nil {
			if errors.Is(err, mountmanager.ErrTakeoverInProgress) {
				writeError(w, http.StatusServiceUnavailable, err.Error())
				return
			}
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, resp)
	}
}
