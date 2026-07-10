package driver

import (
	"context"
	"fmt"
	"time"

	"google.golang.org/grpc"
	resourceapi "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"
	drahealthv1alpha1 "k8s.io/kubelet/pkg/apis/dra-health/v1alpha1"
)

// DriverName is the DRA driver name registered with the kubelet.
const DriverName = "rpi5.brmartin.co.uk"

// DeviceName is the single logical DRA device advertised in this node's ResourceSlice.
const DeviceName = "drm-decoder-0"

// Plugin implements kubeletplugin.DRAPlugin for the Pi5 hardware transcode
// devices. It writes and removes CDI specs on prepare/unprepare.
type Plugin struct {
	drahealthv1alpha1.UnimplementedDRAResourceHealthServer

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

// NodeWatchResources implements the optional kubelet DRAResourceHealth service.
// Kubelet reconnects to this stream and expects a complete device-health list.
// The driver currently has one logical ResourceSlice device on Pi nodes. Report
// it as healthy while the plugin process is running and refresh before kubelet's
// timeout can mark it unknown. Non-Pi nodes may still run the plugin to clean up
// stale allocations; those nodes publish no ResourceSlice and report no health
// devices.
func (p *Plugin) NodeWatchResources(
	_ *drahealthv1alpha1.NodeWatchResourcesRequest,
	stream grpc.ServerStreamingServer[drahealthv1alpha1.NodeWatchResourcesResponse],
) error {
	const refresh = 30 * time.Second

	send := func() error {
		response := &drahealthv1alpha1.NodeWatchResourcesResponse{}
		if p.devices.HasH264 || p.devices.HasHEVC {
			response.Devices = []*drahealthv1alpha1.DeviceHealth{
				{
					Device: &drahealthv1alpha1.DeviceIdentifier{
						PoolName:   p.nodeName,
						DeviceName: DeviceName,
					},
					Health:                    drahealthv1alpha1.HealthStatus_HEALTHY,
					LastUpdatedTime:           time.Now().Unix(),
					HealthCheckTimeoutSeconds: int64((2 * refresh).Seconds()),
					Message:                   "Pi5 DRA device plugin is running",
				},
			}
		}
		return stream.Send(response)
	}

	if err := send(); err != nil {
		return err
	}

	ticker := time.NewTicker(refresh)
	defer ticker.Stop()
	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-ticker.C:
			if err := send(); err != nil {
				return err
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
