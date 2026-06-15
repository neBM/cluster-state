package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestReadinessGateHandler(t *testing.T) {
	gate := newReadinessGate()
	handler := gate.Handler()

	healthReq := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	healthResp := httptest.NewRecorder()
	handler.ServeHTTP(healthResp, healthReq)
	if healthResp.Code != http.StatusOK {
		t.Fatalf("healthz status = %d, want %d", healthResp.Code, http.StatusOK)
	}

	readyReq := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	readyResp := httptest.NewRecorder()
	handler.ServeHTTP(readyResp, readyReq)
	if readyResp.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz before ready = %d, want %d", readyResp.Code, http.StatusServiceUnavailable)
	}

	gate.SetReady(true)

	readyResp = httptest.NewRecorder()
	handler.ServeHTTP(readyResp, readyReq)
	if readyResp.Code != http.StatusOK {
		t.Fatalf("readyz after ready = %d, want %d", readyResp.Code, http.StatusOK)
	}
}
