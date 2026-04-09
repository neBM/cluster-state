package mountmanager

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/seaweedfs/seaweedfs/weed/glog"
	corev1 "k8s.io/api/core/v1"
	eventsv1 "k8s.io/api/events/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// EventRecorder emits k8s Events on the csi-node Pod that owns this
// process. It is intentionally nilable: if env vars are missing or the
// in-cluster config is unavailable, NewEventRecorder returns nil and
// callers must skip recording. This is the graceful-degrade contract.
type EventRecorder struct {
	client    kubernetes.Interface
	namespace string
	podName   string
	hostName  string
}

// NewEventRecorder reads POD_NAME and POD_NAMESPACE from the environment
// (downward API), constructs an in-cluster client, and returns a
// recorder ready for use. Returns nil on any failure — never an error.
func NewEventRecorder() *EventRecorder {
	podName := os.Getenv("POD_NAME")
	ns := os.Getenv("POD_NAMESPACE")
	if podName == "" || ns == "" {
		glog.V(2).Infof("event recorder disabled: POD_NAME or POD_NAMESPACE not set")
		return nil
	}
	cfg, err := rest.InClusterConfig()
	if err != nil {
		glog.V(2).Infof("event recorder disabled: not running in-cluster: %v", err)
		return nil
	}
	cli, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		glog.V(2).Infof("event recorder disabled: kubernetes.NewForConfig: %v", err)
		return nil
	}
	host, _ := os.Hostname()
	return &EventRecorder{
		client:    cli,
		namespace: ns,
		podName:   podName,
		hostName:  host,
	}
}

// RecordMountServiceUnreachable emits a Warning Event on the csi-node
// Pod after the dial retry budget has been exhausted.
func (r *EventRecorder) RecordMountServiceUnreachable(endpoint string, elapsed time.Duration, cause error) {
	if r == nil {
		return
	}
	ev := &eventsv1.Event{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: "mount-service-unreachable-",
			Namespace:    r.namespace,
		},
		EventTime:           metav1.NewMicroTime(time.Now()),
		ReportingController: "seaweedfs-csi-driver",
		ReportingInstance:   r.hostName,
		Type:                corev1.EventTypeWarning,
		Reason:              "MountServiceUnreachable",
		Action:              "DialRetryExhausted",
		Note:                fmt.Sprintf("mount service at %s unreachable after %s during RPC: %v", endpoint, elapsed, cause),
		Regarding: corev1.ObjectReference{
			Kind:      "Pod",
			Name:      r.podName,
			Namespace: r.namespace,
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := r.client.EventsV1().Events(r.namespace).Create(ctx, ev, metav1.CreateOptions{}); err != nil {
		glog.Warningf("failed to record k8s Event: %v", err)
	}
}
