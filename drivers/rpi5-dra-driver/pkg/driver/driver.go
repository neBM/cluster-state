package driver

import (
	"context"
	"fmt"

	resourceapi "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"
)

// DriverName is the DRA driver name registered with the kubelet.
const DriverName = "rpi5.brmartin.co.uk"

// Plugin implements kubeletplugin.DRAPlugin for the Pi5 hardware transcode
// devices. It writes and removes CDI specs on prepare/unprepare.
type Plugin struct {
	devices *Devices
}

// NewPlugin returns a Plugin backed by the supplied device discovery result.
func NewPlugin(devices *Devices) *Plugin {
	return &Plugin{devices: devices}
}

// PrepareResourceClaims implements kubeletplugin.DRAPlugin.
// For each claim it writes a CDI spec and returns the CDI device ID.
func (p *Plugin) PrepareResourceClaims(
	ctx context.Context,
	claims []*resourceapi.ResourceClaim,
) (map[types.UID]kubeletplugin.PrepareResult, error) {
	result := make(map[types.UID]kubeletplugin.PrepareResult, len(claims))

	for _, claim := range claims {
		cdiID, err := WriteCDISpec(p.devices)
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
		if err := RemoveCDISpec(); err != nil {
			klog.Warningf("remove CDI spec for claim %s: %v", claim.UID, err)
			result[claim.UID] = err
		} else {
			result[claim.UID] = nil
		}
	}

	return result, nil
}

// HandleError implements kubeletplugin.DRAPlugin.
// Fatal (non-recoverable) errors are logged at Error level; recoverable
// errors are demoted to Warning.
func (p *Plugin) HandleError(ctx context.Context, err error, msg string) {
	klog.FromContext(ctx).Error(err, msg)
}
