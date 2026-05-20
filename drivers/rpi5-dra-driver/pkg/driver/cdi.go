package driver

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
	"k8s.io/apimachinery/pkg/types"
)

// cdiDir is the directory for CDI spec files. Override in tests.
var cdiDir = "/var/run/cdi"

const cdiKind = "rpi5.brmartin.co.uk/decoder"

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

// WriteCDISpec writes a claim-scoped CDI spec for the Pi5 devices and returns
// the CDI device ID to pass back in NodePrepareResources.
func WriteCDISpec(devices *Devices, claimUID types.UID) (string, error) {
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

	deviceName := cdiDeviceName(claimUID)
	spec := cdiSpec{
		CDIVersion: "0.6.0",
		Kind:       cdiKind,
		Devices: []cdiDevice{
			{
				Name:           deviceName,
				ContainerEdits: cdiEdits{DeviceNodes: nodes},
			},
		},
	}

	data, err := yaml.Marshal(spec)
	if err != nil {
		return "", fmt.Errorf("marshal CDI spec: %w", err)
	}
	if err := os.WriteFile(cdiSpecPath(claimUID), data, 0640); err != nil {
		return "", fmt.Errorf("write CDI spec: %w", err)
	}
	return cdiKind + "=" + deviceName, nil
}

// RemoveCDISpec deletes the claim-scoped CDI spec file written by WriteCDISpec.
func RemoveCDISpec(claimUID types.UID) error {
	if err := os.Remove(cdiSpecPath(claimUID)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func cdiSpecPath(claimUID types.UID) string {
	return filepath.Join(cdiDir, "rpi5-decoder-"+string(claimUID)+".yaml")
}

func cdiDeviceName(claimUID types.UID) string {
	return "claim-" + string(claimUID)
}
