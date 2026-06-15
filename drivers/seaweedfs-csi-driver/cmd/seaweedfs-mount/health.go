package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"sync"

	"github.com/seaweedfs/seaweedfs/weed/glog"
)

type readinessGate struct {
	mu    sync.RWMutex
	ready bool
}

func newReadinessGate() *readinessGate {
	return &readinessGate{}
}

func (g *readinessGate) SetReady(ready bool) {
	g.mu.Lock()
	g.ready = ready
	g.mu.Unlock()
}

func (g *readinessGate) Ready() bool {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.ready
}

func (g *readinessGate) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if !g.Ready() {
			http.Error(w, "starting", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})
	return mux
}

func startHealthServer(address string, gate *readinessGate) (*http.Server, error) {
	if address == "" {
		return nil, nil
	}
	if gate == nil {
		return nil, errors.New("readiness gate is required")
	}

	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, err
	}

	server := &http.Server{Handler: gate.Handler()}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			glog.Fatalf("health server error: %v", err)
		}
	}()
	return server, nil
}

func shutdownHealthServer(ctx context.Context, server *http.Server) {
	if server == nil {
		return
	}
	if err := server.Shutdown(ctx); err != nil {
		glog.Errorf("health server shutdown error: %v", err)
	}
}
