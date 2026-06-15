package mountmanager

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"
)

func TestHasLiveServiceReturnsTrueForHealthyServer(t *testing.T) {
	sockPath, closeFn := newUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	defer closeFn()

	live, err := HasLiveService(context.Background(), "unix://"+sockPath)
	if err != nil {
		t.Fatalf("hasLiveService: %v", err)
	}
	if !live {
		t.Fatal("healthy mount service was not detected as live")
	}
}

func TestHasLiveServiceReturnsFalseForMissingSocket(t *testing.T) {
	sockPath := filepath.Join(t.TempDir(), "missing.sock")

	live, err := HasLiveService(context.Background(), "unix://"+sockPath)
	if err != nil {
		t.Fatalf("hasLiveService: %v", err)
	}
	if live {
		t.Fatal("missing mount service socket unexpectedly reported live")
	}
}

func TestHasLiveServiceErrorsOnUnexpectedStatus(t *testing.T) {
	sockPath, closeFn := newUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer closeFn()

	live, err := HasLiveService(context.Background(), "unix://"+sockPath)
	if err == nil {
		t.Fatal("expected unexpected status probe to fail")
	}
	if live {
		t.Fatal("unexpected-status mount service probe reported live")
	}
}
