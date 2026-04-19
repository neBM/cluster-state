package driver

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// cdiDir is the directory for CDI spec files. Override in tests.
var cdiDir = "/var/run/cdi"

// cdiDeviceID is the CDI device ID returned to the kubelet in
// NodePrepareResources. It must match the kind and device name in the spec.
const cdiDeviceID = "rpi5.brmartin.co.uk/decoder=drm-decoder-0"

type cdiSpec struct {
	CDIVersion string      `yaml:"cdiVersion"`
	Kind       string      `yaml:"kind"`
	Devices    []cdiDevice `yaml:"devices"`
}

type cdiDevice struct {
	Name           string   `yaml:"name"`
	ContainerEdits cdiEdits `yaml:"containerEdits"`
}

type cdiEdits struct {
	DeviceNodes []cdiNode `yaml:"deviceNodes"`
}

type cdiNode struct {
	Path string `yaml:"path"`
}

// WriteCDISpec writes a CDI spec for the Pi5 devices and returns the CDI
// device ID to pass back in NodePrepareResources.
func WriteCDISpec(devices *Devices) (string, error) {
	if err := os.MkdirAll(cdiDir, 0750); err != nil {
		return "", fmt.Errorf("create CDI dir: %w", err)
	}

	var nodes []cdiNode
	if devices.HasH264 {
		nodes = append(nodes, cdiNode{Path: devices.VideoH264})
	}
	if devices.HasHEVC {
		nodes = append(nodes, cdiNode{Path: devices.VideoHEVC})
	}
	if devices.HasRenderNode {
		nodes = append(nodes, cdiNode{Path: devices.RenderNode})
	}

	spec := cdiSpec{
		CDIVersion: "0.6.0",
		Kind:       "rpi5.brmartin.co.uk/decoder",
		Devices: []cdiDevice{
			{
				Name:           "drm-decoder-0",
				ContainerEdits: cdiEdits{DeviceNodes: nodes},
			},
		},
	}

	data, err := yaml.Marshal(spec)
	if err != nil {
		return "", fmt.Errorf("marshal CDI spec: %w", err)
	}
	if err := os.WriteFile(filepath.Join(cdiDir, "rpi5-decoder.yaml"), data, 0640); err != nil {
		return "", fmt.Errorf("write CDI spec: %w", err)
	}
	return cdiDeviceID, nil
}

// RemoveCDISpec deletes the CDI spec file written by WriteCDISpec.
func RemoveCDISpec() error {
	path := filepath.Join(cdiDir, "rpi5-decoder.yaml")
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
