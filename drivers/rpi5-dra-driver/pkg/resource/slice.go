package resource

import (
	"context"
	"fmt"
	"time"

	resourcev1 "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/klog/v2"

	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/driver"
)

const (
	DriverName = "rpi5.brmartin.co.uk"
	DeviceName = "drm-decoder-0"
)

type DiscoverFunc func() (*driver.Devices, bool)

// Publish creates or replaces this node's ResourceSlice. Pass found=false to
// delete any existing slice (used when no Pi5 devices are present).
func Publish(ctx context.Context, client kubernetes.Interface, nodeName string, devices *driver.Devices, found bool) error {
	sliceName := fmt.Sprintf("rpi5-%s", nodeName)

	if !found {
		err := client.ResourceV1().ResourceSlices().Delete(ctx, sliceName, metav1.DeleteOptions{})
		if err != nil && !errors.IsNotFound(err) {
			return fmt.Errorf("delete ResourceSlice: %w", err)
		}
		return nil
	}

	slice := &resourcev1.ResourceSlice{
		ObjectMeta: metav1.ObjectMeta{Name: sliceName},
		Spec: resourcev1.ResourceSliceSpec{
			Driver:   DriverName,
			NodeName: ptr(nodeName),
			Pool: resourcev1.ResourcePool{
				Name:               nodeName,
				Generation:         0,
				ResourceSliceCount: 1,
			},
			Devices: []resourcev1.Device{
				{
					Name: DeviceName,
					Attributes: map[resourcev1.QualifiedName]resourcev1.DeviceAttribute{
						"vendor":     {StringValue: ptr("raspberrypi")},
						"codec_h264": {BoolValue: ptr(devices.HasH264)},
						"codec_hevc": {BoolValue: ptr(devices.HasHEVC)},
					},
				},
			},
		},
	}

	existing, err := client.ResourceV1().ResourceSlices().Get(ctx, sliceName, metav1.GetOptions{})
	if errors.IsNotFound(err) {
		if _, err := client.ResourceV1().ResourceSlices().Create(ctx, slice, metav1.CreateOptions{}); err != nil {
			return fmt.Errorf("create ResourceSlice: %w", err)
		}
		klog.Infof("created ResourceSlice %s", sliceName)
		return nil
	}
	if err != nil {
		return fmt.Errorf("get ResourceSlice: %w", err)
	}

	slice.ResourceVersion = existing.ResourceVersion
	if _, err := client.ResourceV1().ResourceSlices().Update(ctx, slice, metav1.UpdateOptions{}); err != nil {
		return fmt.Errorf("update ResourceSlice: %w", err)
	}
	klog.Infof("updated ResourceSlice %s", sliceName)
	return nil
}

func RepublishLoop(ctx context.Context, client kubernetes.Interface, nodeName string, interval time.Duration, discover DiscoverFunc) {
	if interval <= 0 {
		interval = time.Minute
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if discover == nil {
				klog.Warning("republish loop has no discover function; skipping tick")
				continue
			}

			devices, found := discover()
			if err := Publish(ctx, client, nodeName, devices, found); err != nil {
				klog.Warningf("republish ResourceSlice for node %s: %v", nodeName, err)
			}
		}
	}
}

func ptr[T any](v T) *T { return &v }
