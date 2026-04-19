package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteCDISpecAllDevices(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	devices := &Devices{
		VideoH264:     "/dev/video11",
		VideoHEVC:     "/dev/video19",
		RenderNode:    "/dev/dri/renderD128",
		HasH264:       true,
		HasHEVC:       true,
		HasRenderNode: true,
	}

	id, err := WriteCDISpec(devices)
	if err != nil {
		t.Fatalf("WriteCDISpec: %v", err)
	}
	if id != "rpi5.brmartin.co.uk/decoder=drm-decoder-0" {
		t.Errorf("unexpected CDI ID: %s", id)
	}

	data, err := os.ReadFile(filepath.Join(cdiDir, "rpi5-decoder.yaml"))
	if err != nil {
		t.Fatalf("spec file missing: %v", err)
	}
	spec := string(data)
	for _, want := range []string{"/dev/video11", "/dev/video19", "/dev/dri/renderD128", "drm-decoder-0"} {
		if !strings.Contains(spec, want) {
			t.Errorf("spec missing %q:\n%s", want, spec)
		}
	}
}

func TestWriteCDISpecNoHEVC(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	devices := &Devices{
		VideoH264:  "/dev/video11",
		RenderNode: "/dev/dri/renderD128",
		HasH264:    true,
		HasRenderNode: true,
	}

	_, err := WriteCDISpec(devices)
	if err != nil {
		t.Fatalf("WriteCDISpec: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(cdiDir, "rpi5-decoder.yaml"))
	if strings.Contains(string(data), "video19") {
		t.Error("spec must not contain video19 when HasHEVC=false")
	}
}

func TestRemoveCDISpec(t *testing.T) {
	cdiDir = t.TempDir()
	t.Cleanup(func() { cdiDir = "/var/run/cdi" })

	devices := &Devices{VideoH264: "/dev/video11", HasH264: true}
	if _, err := WriteCDISpec(devices); err != nil {
		t.Fatalf("setup: %v", err)
	}

	if err := RemoveCDISpec(); err != nil {
		t.Fatalf("RemoveCDISpec: %v", err)
	}
	if _, err := os.Stat(filepath.Join(cdiDir, "rpi5-decoder.yaml")); !os.IsNotExist(err) {
		t.Error("spec file should be gone after RemoveCDISpec")
	}
}
