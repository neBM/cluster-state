package driver

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDiscoverFindsNothing(t *testing.T) {
	devRoot = t.TempDir()
	t.Cleanup(func() { devRoot = "/dev" })

	devices, found := Discover()
	if found {
		t.Fatal("expected found=false on empty dir")
	}
	if devices.HasH264 || devices.HasHEVC || devices.HasRenderNode {
		t.Fatal("expected all flags false")
	}
}

func TestDiscoverFindsAllDevices(t *testing.T) {
	tmp := t.TempDir()
	devRoot = tmp
	t.Cleanup(func() { devRoot = "/dev" })

	os.WriteFile(filepath.Join(tmp, "video11"), nil, 0600)
	os.WriteFile(filepath.Join(tmp, "video19"), nil, 0600)
	os.MkdirAll(filepath.Join(tmp, "dri"), 0755)
	os.WriteFile(filepath.Join(tmp, "dri", "renderD128"), nil, 0600)

	devices, found := Discover()
	if !found {
		t.Fatal("expected found=true")
	}
	if !devices.HasH264 || devices.VideoH264 != filepath.Join(tmp, "video11") {
		t.Errorf("H264 device wrong: %+v", devices)
	}
	if !devices.HasHEVC || devices.VideoHEVC != filepath.Join(tmp, "video19") {
		t.Errorf("HEVC device wrong: %+v", devices)
	}
	if !devices.HasRenderNode || devices.RenderNode != filepath.Join(tmp, "dri", "renderD128") {
		t.Errorf("RenderNode wrong: %+v", devices)
	}
}

func TestDiscoverH264OnlyNoHEVC(t *testing.T) {
	tmp := t.TempDir()
	devRoot = tmp
	t.Cleanup(func() { devRoot = "/dev" })

	os.WriteFile(filepath.Join(tmp, "video11"), nil, 0600)

	devices, found := Discover()
	if !found {
		t.Fatal("expected found=true")
	}
	if !devices.HasH264 {
		t.Error("expected HasH264=true")
	}
	if devices.HasHEVC {
		t.Error("expected HasHEVC=false when video19 absent")
	}
	if devices.HasRenderNode {
		t.Error("expected HasRenderNode=false")
	}
}
