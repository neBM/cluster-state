package resource

import (
	"context"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/driver"
)

func TestRepublishLoopRecreatesDeletedSlice(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	client := fake.NewSimpleClientset()
	devices := &driver.Devices{HasHEVC: true}

	if err := Publish(ctx, client, "nyx", devices, true); err != nil {
		t.Fatalf("initial Publish: %v", err)
	}

	go RepublishLoop(ctx, client, "nyx", 10*time.Millisecond, func() (*driver.Devices, bool) {
		return devices, true
	})

	if err := client.ResourceV1().ResourceSlices().Delete(ctx, "rpi5-nyx", metav1.DeleteOptions{}); err != nil {
		t.Fatalf("delete ResourceSlice: %v", err)
	}

	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		_, err := client.ResourceV1().ResourceSlices().Get(ctx, "rpi5-nyx", metav1.GetOptions{})
		if err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("ResourceSlice was not recreated before deadline: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
