package driver

import (
	"context"
	"fmt"
	"time"

	resourceapi "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"
)

// DriverName is the DRA driver name registered with the kubelet.
const DriverName = "rpi5.brmartin.co.uk"

// DeviceName is the single logical DRA device advertised in this node's ResourceSlice.
const DeviceName = "drm-decoder-0"

// Plugin implements kubeletplugin.DRAPlugin for the Pi5 hardware transcode
// devices. It writes and removes CDI specs on prepare/unprepare.
type Plugin struct {
	devices  *Devices
	client   kubernetes.Interface
	nodeName string
}

// NewPlugin returns a Plugin backed by the supplied device discovery result.
func NewPlugin(devices *Devices, client kubernetes.Interface, nodeName string) *Plugin {
	return &Plugin{devices: devices, client: client, nodeName: nodeName}
}

// PrepareResourceClaims implements kubeletplugin.DRAPlugin.
// For each claim it writes a CDI spec and returns the CDI device ID.
func (p *Plugin) PrepareResourceClaims(
	ctx context.Context,
	claims []*resourceapi.ResourceClaim,
) (map[types.UID]kubeletplugin.PrepareResult, error) {
	result := make(map[types.UID]kubeletplugin.PrepareResult, len(claims))

	for _, claim := range claims {
		cdiID, err := WriteCDISpec(p.devices, claim.UID)
		if err != nil {
			result[claim.UID] = kubeletplugin.PrepareResult{
				Err: fmt.Errorf("write CDI spec: %w", err),
			}
			continue
		}

		// Build one kubeletplugin.Device per allocation result so that each
		// request gets the CDI device ID passed through to the container runtime.
		var devices []kubeletplugin.Device
		for _, r := range claim.Status.Allocation.Devices.Results {
			if r.Driver != DriverName {
				continue
			}
			devices = append(devices, kubeletplugin.Device{
				Requests:     []string{r.Request},
				PoolName:     r.Pool,
				DeviceName:   r.Device,
				CDIDeviceIDs: []string{cdiID},
			})
		}

		klog.InfoS("prepared claim", "claimUID", claim.UID, "cdiDevice", cdiID, "deviceCount", len(devices))
		result[claim.UID] = kubeletplugin.PrepareResult{Devices: devices}
	}

	return result, nil
}

// UnprepareResourceClaims implements kubeletplugin.DRAPlugin.
// It removes the CDI spec for each claim.
func (p *Plugin) UnprepareResourceClaims(
	ctx context.Context,
	claims []kubeletplugin.NamespacedObject,
) (map[types.UID]error, error) {
	result := make(map[types.UID]error, len(claims))

	for _, claim := range claims {
		if err := RemoveCDISpec(claim.UID); err != nil {
			klog.Warningf("remove CDI spec for claim %s: %v", claim.UID, err)
			result[claim.UID] = err
		} else {
			klog.InfoS("unprepared claim", "claim", claim)
			result[claim.UID] = nil
		}
	}

	return result, nil
}

// WatchHealthStatus implements kubeletplugin.DRAPlugin.
// Kubelet reconnects to this stream and expects a complete device-health list.
// The driver currently has one logical ResourceSlice device on Pi nodes. Report
// it as healthy while the plugin process is running and refresh before kubelet's
// timeout can mark it unknown. Non-Pi nodes may still run the plugin to clean up
// stale allocations; those nodes publish no ResourceSlice and report no health
// devices.
func (p *Plugin) WatchHealthStatus(ctx context.Context, reports chan<- kubeletplugin.DeviceHealthReport) error {
	const refresh = 30 * time.Second

	send := func() bool {
		report := kubeletplugin.DeviceHealthReport{}
		if p.devices.HasH264 || p.devices.HasHEVC {
			report.Devices = []kubeletplugin.DeviceHealth{
				{
					PoolName:           p.nodeName,
					DeviceName:         DeviceName,
					Health:             kubeletplugin.HealthStatusHealthy,
					LastUpdated:        time.Now(),
					HealthCheckTimeout: 2 * refresh,
					Message:            "Pi5 DRA device plugin is running",
				},
			}
		}

		select {
		case <-ctx.Done():
			return false
		case reports <- report:
			return true
		}
	}

	if !send() {
		return nil
	}

	ticker := time.NewTicker(refresh)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if !send() {
				return nil
			}
		}
	}
}

// HandleError implements kubeletplugin.DRAPlugin.
// Fatal (non-recoverable) errors are logged at Error level; recoverable
// errors are demoted to Warning.
func (p *Plugin) HandleError(ctx context.Context, err error, msg string) {
	klog.FromContext(ctx).Error(err, msg)
}
