package recycler

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const csiDriverName = "seaweedfs-csi-driver"

func newFakeClient(objs ...client.Object) client.Client {
	return fake.NewClientBuilder().WithObjects(objs...).Build()
}

func pod(name, node string, pvcs ...string) *corev1.Pod {
	vols := make([]corev1.Volume, 0, len(pvcs))
	for _, p := range pvcs {
		vols = append(vols, corev1.Volume{
			Name: p,
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: p},
			},
		})
	}
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default", UID: pkUID(name)},
		Spec:       corev1.PodSpec{NodeName: node, Volumes: vols},
		Status:     corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

func pvc(name, pvName string) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       corev1.PersistentVolumeClaimSpec{VolumeName: pvName},
	}
}

func pv(name, driver string) *corev1.PersistentVolume {
	return &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: corev1.PersistentVolumeSpec{
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				CSI: &corev1.CSIPersistentVolumeSource{Driver: driver},
			},
		},
	}
}

func pkUID(name string) types.UID { return types.UID("uid-" + name) }

func TestListCandidates_MatchesOnlySeaweedCSI(t *testing.T) {
	ctx := context.Background()
	c := newFakeClient(
		pod("app1", "nyx", "app1-data"),
		pvc("app1-data", "pv-1"),
		pv("pv-1", csiDriverName),

		pod("app2", "nyx", "app2-data"),
		pvc("app2-data", "pv-2"),
		pv("pv-2", "other.csi.driver"),

		pod("app3", "heracles", "app3-data"),
		pvc("app3-data", "pv-3"),
		pv("pv-3", csiDriverName),
	)

	lookup := &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName}
	got, err := lookup.ListCandidates(ctx)
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 1 || got[0].Name != "app1" {
		t.Fatalf("want [app1], got %v", got)
	}
}

func TestListCandidates_SkipsTerminating(t *testing.T) {
	now := metav1.Now()
	p := pod("app1", "nyx", "app1-data")
	p.DeletionTimestamp = &now
	p.Finalizers = []string{"test/finalizer"} // required by fake client
	c := newFakeClient(p, pvc("app1-data", "pv-1"), pv("pv-1", csiDriverName))
	lookup := &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName}
	got, err := lookup.ListCandidates(context.Background())
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("want no candidates, got %v", got)
	}
}

func TestResolvePodUIDFromMountpoint(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"/var/lib/kubelet/pods/abc-123/volumes/kubernetes.io~csi/pvc-1/mount", "abc-123"},
		{"/var/lib/kubelet/pods/xyz/volumes/kubernetes.io~csi/pvc/mount", "xyz"},
		{"/somewhere/else", ""},
		{"/var/lib/kubelet/pods/", ""},
	}
	for _, tc := range cases {
		if got := ResolvePodUIDFromMountpoint(tc.in); got != tc.want {
			t.Errorf("ResolvePodUIDFromMountpoint(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestListCandidates_SkipsMountDaemonAndRecycler(t *testing.T) {
	mp := pod("seaweedfs-mount-abc", "nyx")
	mp.Labels = map[string]string{"component": "seaweedfs-mount"}
	rp := pod("seaweedfs-consumer-recycler-xyz", "nyx")
	rp.Labels = map[string]string{"app.kubernetes.io/name": "seaweedfs-consumer-recycler"}
	c := newFakeClient(mp, rp)
	lookup := &PVLookup{Client: c, NodeName: "nyx", Driver: csiDriverName}
	got, err := lookup.ListCandidates(context.Background())
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("want no candidates, got %v", got)
	}
}
