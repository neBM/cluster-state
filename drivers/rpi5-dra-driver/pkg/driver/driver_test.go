package driver

import (
	"context"
	"os"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	resourceapi "k8s.io/api/resource/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
)

var _ kubeletplugin.DRAPlugin = (*Plugin)(nil)

func TestWatchHealthStatusReportsDevice(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	reports := make(chan kubeletplugin.DeviceHealthReport)
	errCh := make(chan error, 1)
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset(), "heracles")

	go func() {
		errCh <- plugin.WatchHealthStatus(ctx, reports)
	}()

	select {
	case report := <-reports:
		if len(report.Devices) != 1 {
			t.Fatalf("expected 1 device health status, got %d", len(report.Devices))
		}
		device := report.Devices[0]
		if device.PoolName != "heracles" {
			t.Errorf("unexpected pool name: %q", device.PoolName)
		}
		if device.DeviceName != DeviceName {
			t.Errorf("unexpected device name: %q", device.DeviceName)
		}
		if device.Health != kubeletplugin.HealthStatusHealthy {
			t.Errorf("unexpected health status: %q", device.Health)
		}
		if device.LastUpdated.IsZero() {
			t.Error("expected a health observation timestamp")
		}
		if device.HealthCheckTimeout != time.Minute {
			t.Errorf("unexpected health check timeout: %s", device.HealthCheckTimeout)
		}
		if device.Message != "Pi5 DRA device plugin is running" {
			t.Errorf("unexpected health message: %q", device.Message)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for initial device health report")
	}

	cancel()
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("WatchHealthStatus returned after cancellation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("WatchHealthStatus did not stop after cancellation")
	}
}

func TestPrepareResourceClaimsUsesClaimScopedCDI(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	claimUID := types.UID("0a64caf4-857e-4ba4-b0ea-bd692940350f")
	claim := allocatedClaim(claimUID)
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset(), "heracles")

	result, err := plugin.PrepareResourceClaims(context.Background(), []*resourceapi.ResourceClaim{claim})
	if err != nil {
		t.Fatalf("PrepareResourceClaims: %v", err)
	}

	prepareResult := result[claimUID]
	if prepareResult.Err != nil {
		t.Fatalf("claim prepare failed: %v", prepareResult.Err)
	}
	if len(prepareResult.Devices) != 1 {
		t.Fatalf("expected 1 prepared device, got %d", len(prepareResult.Devices))
	}

	gotCDIIDs := prepareResult.Devices[0].CDIDeviceIDs
	wantCDIID := "rpi5.brmartin.co.uk/decoder=claim-0a64caf4-857e-4ba4-b0ea-bd692940350f"
	if len(gotCDIIDs) != 1 || gotCDIIDs[0] != wantCDIID {
		t.Fatalf("unexpected CDI IDs: %#v", gotCDIIDs)
	}
	if _, err := os.Stat(cdiSpecPath(claimUID)); err != nil {
		t.Fatalf("claim-scoped CDI spec missing: %v", err)
	}
}

func TestUnprepareRemovesSpecEvenWhileClaimReservedForDeletingPod(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	claimUID := types.UID("0a64caf4-857e-4ba4-b0ea-bd692940350f")
	podUID := types.UID("0e5dd75b-13e5-4006-8056-397f1e6674aa")
	claim := claimWithReservations(claimUID, resourceapi.ResourceClaimConsumerReference{
		Resource: "pods",
		Name:     "iris-6799c5d487-pjllt",
		UID:      podUID,
	})
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "iris-6799c5d487-pjllt",
			Namespace: "default",
			UID:       podUID,
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset(claim, pod), "heracles")
	if _, err := WriteCDISpec(testDevices(), claimUID); err != nil {
		t.Fatalf("setup CDI spec: %v", err)
	}

	result, err := plugin.UnprepareResourceClaims(context.Background(), []kubeletplugin.NamespacedObject{namespacedClaim(claimUID)})
	if err != nil {
		t.Fatalf("UnprepareResourceClaims: %v", err)
	}
	if result[claimUID] != nil {
		t.Fatalf("unexpected per-claim unprepare error: %v", result[claimUID])
	}
	if _, err := os.Stat(cdiSpecPath(claimUID)); !os.IsNotExist(err) {
		t.Fatalf("CDI spec should be removed during unprepare, stat err=%v", err)
	}
}

func TestUnprepareRemovesSpecWhenClaimHasNoLiveConsumers(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	claimUID := types.UID("0a64caf4-857e-4ba4-b0ea-bd692940350f")
	podUID := types.UID("stale-pod")
	claim := claimWithReservations(claimUID, resourceapi.ResourceClaimConsumerReference{
		Resource: "pods",
		Name:     "iris-6799c5d487-old",
		UID:      podUID,
	})
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset(claim), "heracles")
	if _, err := WriteCDISpec(testDevices(), claimUID); err != nil {
		t.Fatalf("setup CDI spec: %v", err)
	}

	result, err := plugin.UnprepareResourceClaims(context.Background(), []kubeletplugin.NamespacedObject{namespacedClaim(claimUID)})
	if err != nil {
		t.Fatalf("UnprepareResourceClaims: %v", err)
	}
	if result[claimUID] != nil {
		t.Fatalf("unexpected per-claim unprepare error: %v", result[claimUID])
	}
	if _, err := os.Stat(cdiSpecPath(claimUID)); !os.IsNotExist(err) {
		t.Fatalf("CDI spec should be removed after unprepare, stat err=%v", err)
	}
}

func allocatedClaim(uid types.UID) *resourceapi.ResourceClaim {
	claim := claimWithReservations(uid)
	claim.Status.Allocation = &resourceapi.AllocationResult{
		Devices: resourceapi.DeviceAllocationResult{
			Results: []resourceapi.DeviceRequestAllocationResult{
				{
					Request: "decoder",
					Driver:  DriverName,
					Pool:    "heracles",
					Device:  "drm-decoder-0",
				},
			},
		},
	}
	return claim
}

func claimWithReservations(uid types.UID, consumers ...resourceapi.ResourceClaimConsumerReference) *resourceapi.ResourceClaim {
	return &resourceapi.ResourceClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "iris-transcode",
			Namespace: "default",
			UID:       uid,
		},
		Status: resourceapi.ResourceClaimStatus{ReservedFor: consumers},
	}
}

func namespacedClaim(uid types.UID) kubeletplugin.NamespacedObject {
	return kubeletplugin.NamespacedObject{
		NamespacedName: types.NamespacedName{
			Namespace: "default",
			Name:      "iris-transcode",
		},
		UID: uid,
	}
}

func testDevices() *Devices {
	return &Devices{
		VideoH264:     "/dev/video11",
		VideoHEVC:     "/dev/video19",
		RenderNode:    "/dev/dri/renderD128",
		HasH264:       true,
		HasHEVC:       true,
		HasRenderNode: true,
	}
}
