package k8s

import (
	"context"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// GetPVCAnnotations fetches a PVC by namespace/name via an in-cluster client
// and returns its annotations map. The returned map may be nil if the PVC has
// no annotations. Returns a non-nil error if the PVC cannot be fetched (e.g.
// not found, RBAC denied, network failure) — callers must decide whether to
// treat absence as fatal.
func GetPVCAnnotations(ctx context.Context, namespace, name string) (map[string]string, error) {
	client, err := newInCluster()
	if err != nil {
		return nil, err
	}
	return getPVCAnnotationsWithClient(ctx, client, namespace, name)
}

// getPVCAnnotationsWithClient is the testable seam. Any clientset implementing
// kubernetes.Interface works (real or fake). The caller's ctx is respected; we
// only impose a ceiling timeout if none was provided.
func getPVCAnnotationsWithClient(ctx context.Context, client kubernetes.Interface, namespace, name string) (map[string]string, error) {
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
	}

	pvc, err := client.CoreV1().PersistentVolumeClaims(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("get pvc %s/%s: %w", namespace, name, err)
	}
	return pvc.Annotations, nil
}
