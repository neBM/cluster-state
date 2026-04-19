package driver

import (
	"os"
	"path/filepath"
)

// devRoot is the /dev filesystem root. Override in tests.
var devRoot = "/dev"

// Devices holds the discovered Pi5 decode device paths.
type Devices struct {
	VideoH264     string
	VideoHEVC     string
	RenderNode    string
	HasH264       bool
	HasHEVC       bool
	HasRenderNode bool
}

// Discover probes for Pi5 V4L2 and DRM decode devices. Returns the found
// devices and whether any were present. Safe to call multiple times.
func Discover() (*Devices, bool) {
	d := &Devices{}

	if _, err := os.Stat(filepath.Join(devRoot, "video11")); err == nil {
		d.VideoH264 = filepath.Join(devRoot, "video11")
		d.HasH264 = true
	}
	if _, err := os.Stat(filepath.Join(devRoot, "video19")); err == nil {
		d.VideoHEVC = filepath.Join(devRoot, "video19")
		d.HasHEVC = true
	}

	matches, _ := filepath.Glob(filepath.Join(devRoot, "dri", "renderD*"))
	if len(matches) > 0 {
		d.RenderNode = matches[0]
		d.HasRenderNode = true
	}

	return d, d.HasH264 || d.HasHEVC || d.HasRenderNode
}
