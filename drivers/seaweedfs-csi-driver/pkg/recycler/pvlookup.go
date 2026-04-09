package recycler

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PVLookup enumerates consumer pods on NodeName that hold at least one PVC
// whose bound PV is served by the CSI driver named Driver. Candidates exclude
// pods already Terminating, the seaweedfs-mount DaemonSet pods, and the
// recycler's own pods.
type PVLookup struct {
	Client   client.Client
	NodeName string
	Driver   string
}

// ListCandidates returns the filtered candidate pods for reconciliation.
// Lists all pods and filters by NodeName in-process so tests using the
// controller-runtime fake client (which doesn't honor field selectors by
// default) work. In production the manager's cache is scoped by nodeName,
// so the List here still only sees this node's pods.
func (l *PVLookup) ListCandidates(ctx context.Context) ([]corev1.Pod, error) {
	var pods corev1.PodList
	if err := l.Client.List(ctx, &pods); err != nil {
		return nil, fmt.Errorf("list pods: %w", err)
	}

	var out []corev1.Pod
	for i := range pods.Items {
		p := &pods.Items[i]
		if p.Spec.NodeName != l.NodeName {
			continue
		}
		if p.DeletionTimestamp != nil {
			continue
		}
		if p.Labels["component"] == "seaweedfs-mount" {
			continue
		}
		if p.Labels["app.kubernetes.io/name"] == "seaweedfs-consumer-recycler" {
			continue
		}
		uses, err := l.podUsesDriver(ctx, p)
		if err != nil {
			return nil, err
		}
		if uses {
			out = append(out, *p)
		}
	}
	return out, nil
}

func (l *PVLookup) podUsesDriver(ctx context.Context, p *corev1.Pod) (bool, error) {
	for _, v := range p.Spec.Volumes {
		if v.PersistentVolumeClaim == nil {
			continue
		}
		var pvc corev1.PersistentVolumeClaim
		key := client.ObjectKey{Namespace: p.Namespace, Name: v.PersistentVolumeClaim.ClaimName}
		if err := l.Client.Get(ctx, key, &pvc); err != nil {
			// PVC gone — pod will eventually be terminated by kubelet; skip.
			continue
		}
		if pvc.Spec.VolumeName == "" {
			continue
		}
		var pv corev1.PersistentVolume
		if err := l.Client.Get(ctx, client.ObjectKey{Name: pvc.Spec.VolumeName}, &pv); err != nil {
			continue
		}
		if pv.Spec.CSI != nil && pv.Spec.CSI.Driver == l.Driver {
			return true, nil
		}
	}
	return false, nil
}

// ResolvePodUIDFromMountpoint parses a kubelet CSI mount path of the form
// /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc-name>/mount
// and returns the pod UID segment. Returns "" if the path doesn't match.
func ResolvePodUIDFromMountpoint(mountpoint string) string {
	const prefix = "/var/lib/kubelet/pods/"
	if len(mountpoint) <= len(prefix) || mountpoint[:len(prefix)] != prefix {
		return ""
	}
	rest := mountpoint[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '/' {
			return rest[:i]
		}
	}
	return ""
}
