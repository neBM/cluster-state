package driver

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	resourceapi "k8s.io/api/resource/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"
)

// DriverName is the DRA driver name registered with the kubelet.
const DriverName = "rpi5.brmartin.co.uk"

// Plugin implements kubeletplugin.DRAPlugin for the Pi5 hardware transcode
// devices. It writes and removes CDI specs on prepare/unprepare.
type Plugin struct {
	devices *Devices
	client  kubernetes.Interface
}

// NewPlugin returns a Plugin backed by the supplied device discovery result.
func NewPlugin(devices *Devices, client kubernetes.Interface) *Plugin {
	return &Plugin{devices: devices, client: client}
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
		deferUnprepare, err := p.deferUnprepareForLiveReservation(ctx, claim)
		if err != nil {
			err = fmt.Errorf("check ResourceClaim live reservations: %w", err)
			klog.ErrorS(err, "defer unprepare check failed", "claim", claim)
			result[claim.UID] = err
			continue
		}
		if deferUnprepare {
			err := fmt.Errorf("ResourceClaim %s is still reserved for a live consumer", claim.String())
			klog.InfoS("deferring unprepare for live ResourceClaim", "claim", claim)
			result[claim.UID] = err
			continue
		}

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

func (p *Plugin) deferUnprepareForLiveReservation(ctx context.Context, claim kubeletplugin.NamespacedObject) (bool, error) {
	if p.client == nil {
		return false, nil
	}

	resourceClaim, err := p.client.ResourceV1().ResourceClaims(claim.Namespace).Get(ctx, claim.Name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if resourceClaim.UID != claim.UID {
		return false, nil
	}

	for _, consumer := range resourceClaim.Status.ReservedFor {
		if isLiveConsumer, err := p.isLiveConsumer(ctx, claim.Namespace, consumer); err != nil || isLiveConsumer {
			return isLiveConsumer, err
		}
	}

	return false, nil
}

func (p *Plugin) isLiveConsumer(ctx context.Context, namespace string, consumer resourceapi.ResourceClaimConsumerReference) (bool, error) {
	switch {
	case consumer.APIGroup == "" && consumer.Resource == "pods":
		pod, err := p.client.CoreV1().Pods(namespace).Get(ctx, consumer.Name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		return pod.UID == consumer.UID && pod.Status.Phase != corev1.PodSucceeded && pod.Status.Phase != corev1.PodFailed, nil
	default:
		return true, nil
	}
}

// HandleError implements kubeletplugin.DRAPlugin.
// Fatal (non-recoverable) errors are logged at Error level; recoverable
// errors are demoted to Warning.
func (p *Plugin) HandleError(ctx context.Context, err error, msg string) {
	klog.FromContext(ctx).Error(err, msg)
}
