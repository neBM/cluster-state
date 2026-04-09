package k8s

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestGetPVCAnnotationsWithClient_Found(t *testing.T) {
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plex-config",
			Namespace: "default",
			Annotations: map[string]string{
				"seaweedfs.csi.brmartin.co.uk/mount-root-uid": "990",
				"seaweedfs.csi.brmartin.co.uk/mount-root-gid": "997",
				"unrelated.example.com/other":                 "noise",
			},
		},
	}
	client := fake.NewSimpleClientset(pvc)

	got, err := getPVCAnnotationsWithClient(context.Background(), client, "default", "plex-config")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got["seaweedfs.csi.brmartin.co.uk/mount-root-uid"] != "990" {
		t.Errorf("uid annotation: got %q, want %q", got["seaweedfs.csi.brmartin.co.uk/mount-root-uid"], "990")
	}
	if got["seaweedfs.csi.brmartin.co.uk/mount-root-gid"] != "997" {
		t.Errorf("gid annotation: got %q, want %q", got["seaweedfs.csi.brmartin.co.uk/mount-root-gid"], "997")
	}
	if got["unrelated.example.com/other"] != "noise" {
		t.Errorf("all annotations should be returned, got: %v", got)
	}
}

func TestGetPVCAnnotationsWithClient_NotFound(t *testing.T) {
	client := fake.NewSimpleClientset()
	got, err := getPVCAnnotationsWithClient(context.Background(), client, "default", "missing")
	if err == nil {
		t.Errorf("expected error for missing PVC, got nil, annotations=%v", got)
	}
}

func TestGetPVCAnnotationsWithClient_NoAnnotations(t *testing.T) {
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "bare",
			Namespace: "default",
		},
	}
	client := fake.NewSimpleClientset(pvc)
	got, err := getPVCAnnotationsWithClient(context.Background(), client, "default", "bare")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty annotations, got %v", got)
	}
}
