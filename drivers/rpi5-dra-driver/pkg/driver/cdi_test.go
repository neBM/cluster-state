package driver

import (
	"os"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/types"
)

func TestWriteCDISpecAllDevices(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })
	claimUID := types.UID("claim-uid-1")

	devices := &Devices{
		VideoH264:     "/dev/video11",
		VideoHEVC:     "/dev/video19",
		RenderNode:    "/dev/dri/renderD128",
		HasH264:       true,
		HasHEVC:       true,
		HasRenderNode: true,
	}

	id, err := WriteCDISpec(devices, claimUID)
	if err != nil {
		t.Fatalf("WriteCDISpec: %v", err)
	}
	if id != "rpi5.brmartin.co.uk/decoder=claim-claim-uid-1" {
		t.Errorf("unexpected CDI ID: %s", id)
	}

	data, err := os.ReadFile(cdiSpecPath(claimUID))
	if err != nil {
		t.Fatalf("spec file missing: %v", err)
	}
	spec := string(data)
	for _, want := range []string{"/dev/video11", "/dev/video19", "/dev/dri/renderD128", "claim-claim-uid-1"} {
		if !strings.Contains(spec, want) {
			t.Errorf("spec missing %q:\n%s", want, spec)
		}
	}
}

func TestWriteCDISpecNoHEVC(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })
	claimUID := types.UID("claim-uid-2")

	devices := &Devices{
		VideoH264:     "/dev/video11",
		RenderNode:    "/dev/dri/renderD128",
		HasH264:       true,
		HasRenderNode: true,
	}

	_, err := WriteCDISpec(devices, claimUID)
	if err != nil {
		t.Fatalf("WriteCDISpec: %v", err)
	}

	data, _ := os.ReadFile(cdiSpecPath(claimUID))
	if strings.Contains(string(data), "video19") {
		t.Error("spec must not contain video19 when HasHEVC=false")
	}
}

func TestRemoveCDISpec(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })
	claimUID := types.UID("claim-uid-3")

	devices := &Devices{VideoH264: "/dev/video11", HasH264: true}
	if _, err := WriteCDISpec(devices, claimUID); err != nil {
		t.Fatalf("setup: %v", err)
	}

	if err := RemoveCDISpec(claimUID); err != nil {
		t.Fatalf("RemoveCDISpec: %v", err)
	}
	if _, err := os.Stat(cdiSpecPath(claimUID)); !os.IsNotExist(err) {
		t.Error("spec file should be gone after RemoveCDISpec")
	}
}
