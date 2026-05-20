package driver

import (
	"context"
	"os"
	"testing"

	corev1 "k8s.io/api/core/v1"
	resourceapi "k8s.io/api/resource/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
)

func TestPrepareResourceClaimsUsesClaimScopedCDI(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	claimUID := types.UID("0a64caf4-857e-4ba4-b0ea-bd692940350f")
	claim := allocatedClaim(claimUID)
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset())

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

func TestUnprepareDefersWhileClaimReservedForLivePod(t *testing.T) {
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
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset(claim, pod))
	if _, err := WriteCDISpec(testDevices(), claimUID); err != nil {
		t.Fatalf("setup CDI spec: %v", err)
	}

	result, err := plugin.UnprepareResourceClaims(context.Background(), []kubeletplugin.NamespacedObject{namespacedClaim(claimUID)})
	if err != nil {
		t.Fatalf("UnprepareResourceClaims: %v", err)
	}
	if result[claimUID] == nil {
		t.Fatal("expected per-claim unprepare error while live pod still reserves the claim")
	}
	if _, err := os.Stat(cdiSpecPath(claimUID)); err != nil {
		t.Fatalf("CDI spec should remain while unprepare is deferred: %v", err)
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
	plugin := NewPlugin(testDevices(), fake.NewSimpleClientset(claim))
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
