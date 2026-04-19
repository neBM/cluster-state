# DRA Hardware Transcode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Kubernetes DRA so Iris floats across all three nodes and auto-receives the correct hardware decode devices, while migrating Ollama and Plex off the legacy NVIDIA device plugin.

**Architecture:** Custom `rpi5-dra-driver` DaemonSet (self-selecting) publishes a `ResourceSlice` on Pi5 nodes; the official NVIDIA DRA driver does the same on Hestia. A `DeviceClass` with a CEL OR expression covers both drivers so a single Iris `ResourceClaim` schedules to any node. Ollama and Plex reference an NVIDIA-only `DeviceClass`. The Terraform `kubernetes` provider (v2.38.0) lacks DRA support — all DRA objects use `kubectl_manifest`.

**Tech Stack:** Go 1.25, `k8s.io/dynamic-resource-allocation`, `gopkg.in/yaml.v3`, Terraform (`kubernetes` + `kubectl` + `helm` providers), GitLab CI (Docker-in-Docker).

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `drivers/rpi5-dra-driver/go.mod` | Create | Go module definition |
| `drivers/rpi5-dra-driver/cmd/rpi5-dra-driver/main.go` | Create | Entrypoint: discover, publish, start plugin |
| `drivers/rpi5-dra-driver/pkg/driver/discover.go` | Create | Probe `/dev/video11`, `/dev/video19`, `/dev/dri/renderD*` |
| `drivers/rpi5-dra-driver/pkg/driver/discover_test.go` | Create | Unit tests for discovery |
| `drivers/rpi5-dra-driver/pkg/driver/cdi.go` | Create | Write/delete CDI spec YAML |
| `drivers/rpi5-dra-driver/pkg/driver/cdi_test.go` | Create | Unit tests for CDI spec |
| `drivers/rpi5-dra-driver/pkg/driver/driver.go` | Create | DRA kubelet plugin gRPC handler |
| `drivers/rpi5-dra-driver/pkg/resource/slice.go` | Create | Create/update/delete ResourceSlice |
| `drivers/rpi5-dra-driver/Dockerfile` | Create | Multi-stage build |
| `drivers/rpi5-dra-driver/Makefile` | Create | Build/push targets |
| `drivers/rpi5-dra-driver/.gitignore` | Create | Exclude `_output/` |
| `modules-k8s/rpi5-dra-driver/main.tf` | Create | DaemonSet + RBAC |
| `modules-k8s/rpi5-dra-driver/variables.tf` | Create | Image variable |
| `modules-k8s/rpi5-dra-driver/versions.tf` | Create | Provider constraint |
| `modules-k8s/nvidia-dra-driver/main.tf` | Create | Helm release |
| `modules-k8s/nvidia-dra-driver/variables.tf` | Create | Chart version + time-slice count |
| `modules-k8s/nvidia-dra-driver/versions.tf` | Create | Helm provider constraint |
| `modules-k8s/device-classes/main.tf` | Create | `nvidia-gpu` + `iris-transcode-hw` DeviceClasses |
| `modules-k8s/device-classes/versions.tf` | Create | kubectl provider constraint |
| `modules-k8s/ollama/main.tf` | Modify | Replace `nvidia.com/gpu` with ResourceClaim |
| `modules-k8s/media-centre/main.tf` | Modify | Replace `nvidia.com/gpu` with ResourceClaim |
| `modules-k8s/iris/main.tf` | Modify | Add `iris-transcode-hw` ResourceClaim |
| `provider.tf` | Modify | Add Helm provider |
| `kubernetes.tf` | Modify | Wire new modules |
| `.gitlab-ci.yml` | Modify | Add `build` stage for rpi5-dra-driver |

---

## Task 1: Research Spike — CDI and runtimeClassName

**This task gates Tasks 8 (Ollama) and 9 (Plex). Complete before those tasks.**

With DRA + CDI, device injection moves from the NVIDIA container runtime hook into the CDI layer. This task determines whether `runtime_class_name = "nvidia"` on Ollama and Plex pods must be removed.

- [ ] **Step 1: Read NVIDIA DRA driver example pod specs**

Fetch the demo directory from the NVIDIA DRA driver repo and look for example pod specs:
```
https://github.com/NVIDIA/k8s-dra-driver-gpu/tree/main/demo
```
Note whether example pods set `runtimeClassName`.

- [ ] **Step 2: Check NVIDIA DRA docs on CDI and runtime class**

Fetch:
```
https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/dra-intro-install.html
```
Search for "runtimeClass", "CDI", "NVIDIA_VISIBLE_DEVICES". Note the verdict.

- [ ] **Step 3: Record verdict in this plan**

Edit this file and replace the `[VERDICT]` marker in Tasks 8 and 9 with one of:
- **REMOVE** `runtime_class_name = "nvidia"` — CDI handles injection, NVIDIA runtime not needed
- **KEEP** `runtime_class_name = "nvidia"` — still required alongside DRA
- **CHANGE TO** `runtime_class_name = "<other>"` — specify the replacement

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-04-19-dra-hardware-transcode.md
git commit -m "docs(plan): record CDI + runtimeClassName verdict for DRA migration"
```

---

## Task 2: rpi5-dra-driver — Go Module Scaffold

**Files:**
- Create: `drivers/rpi5-dra-driver/go.mod`
- Create: `drivers/rpi5-dra-driver/cmd/rpi5-dra-driver/main.go` (stub)
- Create: `drivers/rpi5-dra-driver/.gitignore`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p drivers/rpi5-dra-driver/cmd/rpi5-dra-driver
mkdir -p drivers/rpi5-dra-driver/pkg/driver
mkdir -p drivers/rpi5-dra-driver/pkg/resource
mkdir -p drivers/rpi5-dra-driver/_output
```

- [ ] **Step 2: Create go.mod**

Create `drivers/rpi5-dra-driver/go.mod`:

```
module rpi5.brmartin.co.uk/rpi5-dra-driver

go 1.25.0

require (
	gopkg.in/yaml.v3 v3.0.1
	k8s.io/api v0.33.0
	k8s.io/apimachinery v0.33.0
	k8s.io/client-go v0.33.0
	k8s.io/dynamic-resource-allocation v0.33.0
	k8s.io/klog/v2 v2.130.1
	k8s.io/kubelet v0.33.0
)
```

- [ ] **Step 3: Create stub main.go**

Create `drivers/rpi5-dra-driver/cmd/rpi5-dra-driver/main.go`:

```go
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/klog/v2"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	klog.Info("rpi5-dra-driver starting")
	<-ctx.Done()
	klog.Info("rpi5-dra-driver shutting down")
}
```

- [ ] **Step 4: Create .gitignore**

Create `drivers/rpi5-dra-driver/.gitignore`:

```
_output/
```

- [ ] **Step 5: Run go mod tidy and verify build**

```bash
cd drivers/rpi5-dra-driver && go mod tidy && go build ./...
```

Expected: `go.sum` created, binary compiles, no errors.

- [ ] **Step 6: Commit**

```bash
git add drivers/rpi5-dra-driver/
git commit -m "feat(rpi5-dra-driver): scaffold Go module"
```

---

## Task 3: rpi5-dra-driver — Device Discovery

**Files:**
- Create: `drivers/rpi5-dra-driver/pkg/driver/discover.go`
- Create: `drivers/rpi5-dra-driver/pkg/driver/discover_test.go`

- [ ] **Step 1: Write the failing tests**

Create `drivers/rpi5-dra-driver/pkg/driver/discover_test.go`:

```go
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
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
cd drivers/rpi5-dra-driver && go test ./pkg/driver/ -run TestDiscover -v
```

Expected: compile error — `Discover`, `devRoot`, `Devices` undefined.

- [ ] **Step 3: Implement discover.go**

Create `drivers/rpi5-dra-driver/pkg/driver/discover.go`:

```go
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
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd drivers/rpi5-dra-driver && go test ./pkg/driver/ -run TestDiscover -v
```

Expected: `PASS` for all three tests.

- [ ] **Step 5: Commit**

```bash
git add drivers/rpi5-dra-driver/pkg/driver/
git commit -m "feat(rpi5-dra-driver): device discovery for Pi5 V4L2/DRM"
```

---

## Task 4: rpi5-dra-driver — CDI Spec Writer

**Files:**
- Create: `drivers/rpi5-dra-driver/pkg/driver/cdi.go`
- Create: `drivers/rpi5-dra-driver/pkg/driver/cdi_test.go`

CDI (Container Device Interface) specs are YAML files in `/var/run/cdi/` that tell containerd which device nodes to inject. We write the spec on `NodePrepareResources` and delete it on `NodeUnprepareResources`. The CDI device ID returned to the kubelet is the lookup key for this spec.

- [ ] **Step 1: Write the failing tests**

Create `drivers/rpi5-dra-driver/pkg/driver/cdi_test.go`:

```go
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
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
cd drivers/rpi5-dra-driver && go test ./pkg/driver/ -run "TestWriteCDI|TestRemoveCDI" -v
```

Expected: compile error — `WriteCDISpec`, `RemoveCDISpec`, `cdiDir` undefined.

- [ ] **Step 3: Implement cdi.go**

Create `drivers/rpi5-dra-driver/pkg/driver/cdi.go`:

```go
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
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd drivers/rpi5-dra-driver && go test ./pkg/driver/ -run "TestWriteCDI|TestRemoveCDI" -v
```

Expected: all three CDI tests PASS.

- [ ] **Step 5: Commit**

```bash
git add drivers/rpi5-dra-driver/pkg/driver/
git commit -m "feat(rpi5-dra-driver): CDI spec writer for Pi5 decoder devices"
```

---

## Task 5: rpi5-dra-driver — ResourceSlice Publisher

**Files:**
- Create: `drivers/rpi5-dra-driver/pkg/resource/slice.go`

Publishes a `ResourceSlice` to the Kubernetes API server advertising this node's Pi5 decoder. If called with `found=false`, deletes any existing slice for this node.

- [ ] **Step 1: Create slice.go**

Create `drivers/rpi5-dra-driver/pkg/resource/slice.go`:

```go
package resource

import (
	"context"
	"fmt"

	resourcev1beta1 "k8s.io/api/resource/v1beta1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/klog/v2"

	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/driver"
)

const (
	DriverName = "rpi5.brmartin.co.uk"
	DeviceName = "drm-decoder-0"
)

// Publish creates or replaces this node's ResourceSlice. Pass found=false to
// delete any existing slice (used when no Pi5 devices are present).
func Publish(ctx context.Context, client kubernetes.Interface, nodeName string, devices *driver.Devices, found bool) error {
	sliceName := fmt.Sprintf("rpi5-%s", nodeName)

	if !found {
		err := client.ResourceV1beta1().ResourceSlices().Delete(ctx, sliceName, metav1.DeleteOptions{})
		if err != nil && !errors.IsNotFound(err) {
			return fmt.Errorf("delete ResourceSlice: %w", err)
		}
		return nil
	}

	slice := &resourcev1beta1.ResourceSlice{
		ObjectMeta: metav1.ObjectMeta{Name: sliceName},
		Spec: resourcev1beta1.ResourceSliceSpec{
			Driver:   DriverName,
			NodeName: nodeName,
			Pool: resourcev1beta1.ResourcePool{
				Name:               nodeName,
				Generation:         0,
				ResourceSliceCount: 1,
			},
			Devices: []resourcev1beta1.Device{
				{
					Name: DeviceName,
					Basic: &resourcev1beta1.BasicDevice{
						Attributes: map[resourcev1beta1.QualifiedName]resourcev1beta1.DeviceAttribute{
							"vendor":     {StringValue: ptr("raspberrypi")},
							"codec.h264": {BoolValue: ptr(devices.HasH264)},
							"codec.hevc": {BoolValue: ptr(devices.HasHEVC)},
						},
					},
				},
			},
		},
	}

	existing, err := client.ResourceV1beta1().ResourceSlices().Get(ctx, sliceName, metav1.GetOptions{})
	if errors.IsNotFound(err) {
		if _, err := client.ResourceV1beta1().ResourceSlices().Create(ctx, slice, metav1.CreateOptions{}); err != nil {
			return fmt.Errorf("create ResourceSlice: %w", err)
		}
		klog.Infof("created ResourceSlice %s", sliceName)
		return nil
	}
	if err != nil {
		return fmt.Errorf("get ResourceSlice: %w", err)
	}

	slice.ResourceVersion = existing.ResourceVersion
	if _, err := client.ResourceV1beta1().ResourceSlices().Update(ctx, slice, metav1.UpdateOptions{}); err != nil {
		return fmt.Errorf("update ResourceSlice: %w", err)
	}
	klog.Infof("updated ResourceSlice %s", sliceName)
	return nil
}

func ptr[T any](v T) *T { return &v }
```

- [ ] **Step 2: Verify compilation**

```bash
cd drivers/rpi5-dra-driver && go build ./...
```

Expected: no errors. If `ResourceV1beta1()` is not found on `kubernetes.Interface`, the API may be at `ResourceV1()`. Check with:
```bash
grep -r "ResourceSlices" $(go env GOPATH)/pkg/mod/k8s.io/client-go@*/kubernetes/typed/resource/ 2>/dev/null | grep "func " | head -5
```
Update the method call accordingly.

- [ ] **Step 3: Commit**

```bash
git add drivers/rpi5-dra-driver/pkg/resource/
git commit -m "feat(rpi5-dra-driver): ResourceSlice publisher"
```

---

## Task 6: rpi5-dra-driver — Kubelet Plugin

**Files:**
- Create: `drivers/rpi5-dra-driver/pkg/driver/driver.go`

Implements the DRA kubelet plugin interface. On `NodePrepareResources`, writes the CDI spec and returns the CDI device ID. On `NodeUnprepareResources`, removes the spec.

- [ ] **Step 1: Discover the exact kubelet plugin API path**

```bash
cd drivers/rpi5-dra-driver
ls $(go env GOPATH)/pkg/mod/k8s.io/kubelet@v0.33.0/pkg/apis/dra/ 2>/dev/null || \
  find $(go env GOPATH)/pkg/mod/k8s.io/kubelet@v0.33.0 -name "*.go" -path "*/dra/*" | head -5
```

Note the API version directory (e.g. `v1alpha4`, `v1beta1`). Use it in the import below.

- [ ] **Step 2: Create driver.go**

Create `drivers/rpi5-dra-driver/pkg/driver/driver.go`, replacing `v1beta1` with the version found in Step 1:

```go
package driver

import (
	"context"
	"fmt"

	drapb "k8s.io/kubelet/pkg/apis/dra/v1beta1"
	"k8s.io/klog/v2"
)

const DriverName = "rpi5.brmartin.co.uk"

// Plugin implements the DRA kubelet plugin gRPC interface.
type Plugin struct {
	devices *Devices
}

func NewPlugin(devices *Devices) *Plugin {
	return &Plugin{devices: devices}
}

// NodePrepareResources is called by the kubelet before starting a pod that
// claimed a Pi5 decoder. We write the CDI spec and return the CDI device ID.
func (p *Plugin) NodePrepareResources(
	ctx context.Context,
	req *drapb.NodePrepareResourcesRequest,
) (*drapb.NodePrepareResourcesResponse, error) {
	resp := &drapb.NodePrepareResourcesResponse{
		Claims: make(map[string]*drapb.NodePrepareResourceResponse),
	}

	for _, claim := range req.Claims {
		cdiID, err := WriteCDISpec(p.devices)
		if err != nil {
			resp.Claims[claim.UID] = &drapb.NodePrepareResourceResponse{
				Error: fmt.Sprintf("write CDI spec: %v", err),
			}
			continue
		}
		klog.Infof("prepared claim %s with CDI device %s", claim.UID, cdiID)
		resp.Claims[claim.UID] = &drapb.NodePrepareResourceResponse{
			Devices: []*drapb.Device{
				{RequestNames: []string{"transcode"}, CDIDeviceIDs: []string{cdiID}},
			},
		}
	}
	return resp, nil
}

// NodeUnprepareResources is called by the kubelet after the pod stops.
func (p *Plugin) NodeUnprepareResources(
	ctx context.Context,
	req *drapb.NodeUnprepareResourcesRequest,
) (*drapb.NodeUnprepareResourcesResponse, error) {
	resp := &drapb.NodeUnprepareResourcesResponse{
		Claims: make(map[string]*drapb.NodeUnprepareResourceResponse),
	}
	for _, claim := range req.Claims {
		if err := RemoveCDISpec(); err != nil {
			klog.Warningf("remove CDI spec for claim %s: %v", claim.UID, err)
		}
		resp.Claims[claim.UID] = &drapb.NodeUnprepareResourceResponse{}
	}
	return resp, nil
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd drivers/rpi5-dra-driver && go build ./...
```

If the drapb proto types differ (e.g. `Claim` struct has no `UID` field, or response structs differ), inspect the actual types:
```bash
grep -n "type Claim\|type NodePrepareResourcesResponse\|type NodePrepareResourceResponse\b" \
  $(go env GOPATH)/pkg/mod/k8s.io/kubelet@v0.33.0/pkg/apis/dra/v1beta1/*.go 2>/dev/null
```
Adjust field names to match.

- [ ] **Step 4: Commit**

```bash
git add drivers/rpi5-dra-driver/pkg/driver/driver.go
git commit -m "feat(rpi5-dra-driver): DRA kubelet plugin (NodePrepare/Unprepare)"
```

---

## Task 7: rpi5-dra-driver — Entrypoint, Dockerfile, Makefile

**Files:**
- Modify: `drivers/rpi5-dra-driver/cmd/rpi5-dra-driver/main.go`
- Create: `drivers/rpi5-dra-driver/Dockerfile`
- Create: `drivers/rpi5-dra-driver/Makefile`

- [ ] **Step 1: Implement main.go**

Overwrite `drivers/rpi5-dra-driver/cmd/rpi5-dra-driver/main.go`:

```go
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"

	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/driver"
	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/resource"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		klog.Fatal("NODE_NAME env var required")
	}

	cfg, err := rest.InClusterConfig()
	if err != nil {
		klog.Fatalf("in-cluster config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		klog.Fatalf("kubernetes client: %v", err)
	}

	devices, found := driver.Discover()

	if err := resource.Publish(ctx, client, nodeName, devices, found); err != nil {
		klog.Fatalf("publish ResourceSlice: %v", err)
	}

	if !found {
		klog.Info("no Pi5 decode devices found — idling")
		<-ctx.Done()
		return
	}

	klog.Infof("Pi5 devices: H264=%v HEVC=%v RenderNode=%v",
		devices.HasH264, devices.HasHEVC, devices.HasRenderNode)

	plugin := driver.NewPlugin(devices)
	socketBase := "/var/lib/kubelet/plugins/" + driver.DriverName
	dp, err := kubeletplugin.Start(ctx, plugin,
		kubeletplugin.DriverName(driver.DriverName),
		kubeletplugin.KubeletPluginSocketPath(socketBase+"/plugin.sock"),
		kubeletplugin.RegistrarSocketPath("/var/lib/kubelet/plugins_registry/"+driver.DriverName+"-reg.sock"),
	)
	if err != nil {
		klog.Fatalf("start kubelet plugin: %v", err)
	}
	defer dp.Stop()

	klog.Info("rpi5-dra-driver running")
	<-ctx.Done()
}
```

Note: `kubeletplugin.Start` signature varies by library version. If it doesn't accept `Option` funcs, inspect the actual API:
```bash
grep -n "func Start" $(go env GOPATH)/pkg/mod/k8s.io/dynamic-resource-allocation@v0.33.0/kubeletplugin/*.go
```
Adapt the call to match.

- [ ] **Step 2: Verify compilation**

```bash
cd drivers/rpi5-dra-driver && go mod tidy && go build ./...
```

- [ ] **Step 3: Create Dockerfile**

Create `drivers/rpi5-dra-driver/Dockerfile`:

```dockerfile
FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-s -w' \
    -o /rpi5-dra-driver ./cmd/rpi5-dra-driver

FROM alpine:3.21
COPY --from=builder /rpi5-dra-driver /rpi5-dra-driver
ENTRYPOINT ["/rpi5-dra-driver"]
```

- [ ] **Step 4: Create Makefile**

Create `drivers/rpi5-dra-driver/Makefile`:

```makefile
REGISTRY ?= registry.brmartin.co.uk/ben/cluster-state
IMAGE     := $(REGISTRY)/rpi5-dra-driver
COMMIT    := $(shell git rev-parse --short HEAD)
VERSION   ?= dev
OUTPUT    := _output/rpi5-dra-driver

.PHONY: build container push clean deps

deps:
	go mod tidy

build: $(OUTPUT)

$(OUTPUT):
	mkdir -p _output
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-s -w' -o $(OUTPUT) ./cmd/rpi5-dra-driver

container: build
	docker build -t $(IMAGE):$(VERSION) -t $(IMAGE):$(COMMIT) .

push: container
	docker push $(IMAGE):$(VERSION)
	docker push $(IMAGE):$(COMMIT)

clean:
	rm -rf _output
```

- [ ] **Step 5: Run all tests one final time**

```bash
cd drivers/rpi5-dra-driver && go test ./... -v
```

Expected: all tests PASS, no compilation errors.

- [ ] **Step 6: Commit**

```bash
git add drivers/rpi5-dra-driver/
git commit -m "feat(rpi5-dra-driver): complete driver with Dockerfile and Makefile"
```

---

## Task 8: GitLab CI — Build Stage

**Files:**
- Modify: `.gitlab-ci.yml`

- [ ] **Step 1: Read .gitlab-ci.yml**

Already read above. Current stages: `validate`, `plan`, `apply`.

- [ ] **Step 2: Add build stage and job**

Edit `.gitlab-ci.yml`. Add `build` to the stages list and append the job:

```yaml
stages:
  - build      # <-- add this
  - validate
  - plan
  - apply
```

Append after the existing `variables` block:

```yaml
build-rpi5-dra-driver:
  stage: build
  image: docker:27
  services:
    - docker:27-dind
  variables:
    DOCKER_TLS_CERTDIR: "/certs"
  before_script:
    - docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
  script:
    - |
      docker build \
        -t "$CI_REGISTRY_IMAGE/rpi5-dra-driver:$CI_COMMIT_SHORT_SHA" \
        -t "$CI_REGISTRY_IMAGE/rpi5-dra-driver:latest" \
        drivers/rpi5-dra-driver/
    - docker push "$CI_REGISTRY_IMAGE/rpi5-dra-driver:$CI_COMMIT_SHORT_SHA"
    - docker push "$CI_REGISTRY_IMAGE/rpi5-dra-driver:latest"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - drivers/rpi5-dra-driver/**/*
```

- [ ] **Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))" && echo "OK"
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add build stage for rpi5-dra-driver image"
```

---

## Task 9: Terraform — rpi5-dra-driver DaemonSet Module

**Files:**
- Create: `modules-k8s/rpi5-dra-driver/versions.tf`
- Create: `modules-k8s/rpi5-dra-driver/variables.tf`
- Create: `modules-k8s/rpi5-dra-driver/main.tf`

- [ ] **Step 1: Create versions.tf**

Create `modules-k8s/rpi5-dra-driver/versions.tf`:

```hcl
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20.0"
    }
  }
}
```

- [ ] **Step 2: Create variables.tf**

Create `modules-k8s/rpi5-dra-driver/variables.tf`:

```hcl
variable "image" {
  description = "rpi5-dra-driver container image including tag"
  type        = string
  default     = "registry.brmartin.co.uk/ben/cluster-state/rpi5-dra-driver:latest"
}
```

- [ ] **Step 3: Create main.tf**

Create `modules-k8s/rpi5-dra-driver/main.tf`:

```hcl
locals {
  name   = "rpi5-dra-driver"
  labels = { app = local.name, "managed-by" = "terraform" }
}

resource "kubernetes_service_account" "driver" {
  metadata {
    name      = local.name
    namespace = "kube-system"
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role" "driver" {
  metadata {
    name   = local.name
    labels = local.labels
  }
  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["resourceslices"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "driver" {
  metadata {
    name   = local.name
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.driver.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.driver.metadata[0].name
    namespace = "kube-system"
  }
}

resource "kubernetes_daemon_set_v1" "driver" {
  metadata {
    name      = local.name
    namespace = "kube-system"
    labels    = local.labels
  }

  spec {
    selector { match_labels = local.labels }

    template {
      metadata { labels = local.labels }

      spec {
        service_account_name = kubernetes_service_account.driver.metadata[0].name
        priority_class_name  = "system-node-critical"

        container {
          name              = "driver"
          image             = var.image
          image_pull_policy = "Always"

          env {
            name = "NODE_NAME"
            value_from {
              field_ref { field_path = "spec.nodeName" }
            }
          }

          security_context { privileged = true }

          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }
          volume_mount {
            name       = "kubelet-plugins"
            mount_path = "/var/lib/kubelet/plugins"
          }
          volume_mount {
            name       = "kubelet-registry"
            mount_path = "/var/lib/kubelet/plugins_registry"
          }
          volume_mount {
            name       = "cdi"
            mount_path = "/var/run/cdi"
          }
        }

        volume {
          name = "dev"
          host_path { path = "/dev" }
        }
        volume {
          name = "kubelet-plugins"
          host_path { path = "/var/lib/kubelet/plugins" }
        }
        volume {
          name = "kubelet-registry"
          host_path { path = "/var/lib/kubelet/plugins_registry" }
        }
        volume {
          name = "cdi"
          host_path {
            path = "/var/run/cdi"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add modules-k8s/rpi5-dra-driver/
git commit -m "feat(terraform): rpi5-dra-driver DaemonSet + RBAC module"
```

---

## Task 10: Terraform — NVIDIA DRA Driver Module

**Files:**
- Modify: `provider.tf`
- Create: `modules-k8s/nvidia-dra-driver/versions.tf`
- Create: `modules-k8s/nvidia-dra-driver/variables.tf`
- Create: `modules-k8s/nvidia-dra-driver/main.tf`

The NVIDIA DRA driver ships as a Helm chart. Add the Helm Terraform provider.

- [ ] **Step 1: Read provider.tf**

Read `provider.tf` to see the current content before editing.

- [ ] **Step 2: Add Helm provider to provider.tf**

Add `helm` to the `required_providers` block and add a `provider "helm"` block:

```hcl
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/k3s-config"
    config_context = "default"
  }
}
```

- [ ] **Step 3: Run terraform init to download the Helm provider**

```bash
terraform init
```

Expected: Helm provider downloaded. `.terraform.lock.hcl` updated.

- [ ] **Step 4: Create nvidia-dra-driver/versions.tf**

Create `modules-k8s/nvidia-dra-driver/versions.tf`:

```hcl
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0"
    }
  }
}
```

- [ ] **Step 5: Create nvidia-dra-driver/variables.tf**

Create `modules-k8s/nvidia-dra-driver/variables.tf`:

```hcl
variable "chart_version" {
  description = "NVIDIA k8s-dra-driver-gpu Helm chart version"
  type        = string
}

variable "gpu_time_slice_replicas" {
  description = "GPU time-slice replica count — must match current device plugin config (was 2)"
  type        = number
  default     = 2
}
```

- [ ] **Step 6: Look up the Helm chart repo and values path**

Before creating main.tf, verify the exact chart name, repo URL, and time-slicing values path:
```
https://github.com/NVIDIA/k8s-dra-driver-gpu/tree/main/deployments/helm
```
Find the chart name and the correct `set` path for `sharing.timeSlicing.replicas` (or equivalent).

- [ ] **Step 7: Create nvidia-dra-driver/main.tf**

Create `modules-k8s/nvidia-dra-driver/main.tf` using the verified chart name and repo:

```hcl
resource "helm_release" "nvidia_dra_driver" {
  name             = "nvidia-dra-driver-gpu"
  repository       = "https://helm.ngc.nvidia.com/nvidia"   # verify this URL
  chart            = "k8s-dra-driver-gpu"                   # verify chart name
  version          = var.chart_version
  namespace        = "nvidia-dra-driver"
  create_namespace = true

  # Preserve time-sliced GPU sharing: Plex + Ollama run concurrently
  set {
    name  = "sharing.timeSlicing.replicas"   # verify this values path
    value = tostring(var.gpu_time_slice_replicas)
  }
}
```

- [ ] **Step 8: Commit**

```bash
git add provider.tf modules-k8s/nvidia-dra-driver/ .terraform.lock.hcl
git commit -m "feat(terraform): NVIDIA DRA driver Helm module + Helm provider"
```

---

## Task 11: Terraform — DeviceClasses Module

**Files:**
- Create: `modules-k8s/device-classes/versions.tf`
- Create: `modules-k8s/device-classes/main.tf`

`DeviceClass` is not in the `hashicorp/kubernetes` provider — use `kubectl_manifest`.

- [ ] **Step 1: Create versions.tf**

Create `modules-k8s/device-classes/versions.tf`:

```hcl
terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.0"
    }
  }
}
```

- [ ] **Step 2: Create main.tf**

Create `modules-k8s/device-classes/main.tf`:

```hcl
# nvidia-gpu — used by Ollama and Plex (Hestia only via NVIDIA DRA driver)
resource "kubectl_manifest" "nvidia_gpu" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1beta1"
    kind       = "DeviceClass"
    metadata   = { name = "nvidia-gpu" }
    spec = {
      selectors = [{
        cel = { expression = "device.driver == \"gpu.nvidia.com\"" }
      }]
    }
  })
}

# iris-transcode-hw — used by Iris (any node: NVIDIA or Pi5 DRM)
resource "kubectl_manifest" "iris_transcode_hw" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1beta1"
    kind       = "DeviceClass"
    metadata   = { name = "iris-transcode-hw" }
    spec = {
      selectors = [{
        cel = { expression = "device.driver in [\"gpu.nvidia.com\", \"rpi5.brmartin.co.uk\"]" }
      }]
    }
  })
}
```

- [ ] **Step 3: Commit**

```bash
git add modules-k8s/device-classes/
git commit -m "feat(terraform): DeviceClass definitions for nvidia-gpu and iris-transcode-hw"
```

---

## Task 12: Terraform — Wire Modules into kubernetes.tf

**Files:**
- Modify: `kubernetes.tf`

- [ ] **Step 1: Read kubernetes.tf**

Read `kubernetes.tf` to find the module list and a suitable insertion point.

- [ ] **Step 2: Add three module blocks**

Add the following to `kubernetes.tf`:

```hcl
module "k8s_rpi5_dra_driver" {
  source = "./modules-k8s/rpi5-dra-driver"
}

module "k8s_nvidia_dra_driver" {
  source        = "./modules-k8s/nvidia-dra-driver"
  chart_version = "0.1.0"   # replace with verified chart version from Task 10
}

module "k8s_device_classes" {
  source     = "./modules-k8s/device-classes"
  depends_on = [module.k8s_nvidia_dra_driver, module.k8s_rpi5_dra_driver]
}
```

- [ ] **Step 3: Validate and plan**

```bash
terraform init && terraform validate
```

Expected: `Success! The configuration is valid.`

```bash
terraform plan \
  -target=module.k8s_rpi5_dra_driver \
  -target=module.k8s_nvidia_dra_driver \
  -target=module.k8s_device_classes
```

Expected: only new resources — no changes to existing workloads.

- [ ] **Step 4: Commit**

```bash
git add kubernetes.tf .terraform.lock.hcl
git commit -m "feat(terraform): wire rpi5-dra-driver, nvidia-dra-driver, device-classes"
```

---

## Task 13: Workload Migration — Ollama

> **Gate:** Task 1 (CDI research) must be complete.
> **runtimeClassName verdict:** [VERDICT — fill in from Task 1]

**Files:**
- Modify: `modules-k8s/ollama/main.tf`

- [ ] **Step 1: Read modules-k8s/ollama/main.tf**

Read the full file. The current state has: `runtime_class_name = "nvidia"`, `node_selector` for hestia, `nvidia.com/gpu` in requests/limits, `NVIDIA_VISIBLE_DEVICES` + `NVIDIA_DRIVER_CAPABILITIES` env vars, and a GPU toleration.

- [ ] **Step 2: Remove legacy GPU config from the deployment**

In `kubernetes_deployment.ollama`:

**Remove** `runtime_class_name = "nvidia"` (or keep/change per Task 1 verdict).

**Remove** both env blocks:
```hcl
env {
  name  = "NVIDIA_DRIVER_CAPABILITIES"
  value = "all"
}
env {
  name  = "NVIDIA_VISIBLE_DEVICES"
  value = "all"
}
```

**Remove** `"nvidia.com/gpu" = "1"` from both `requests` and `limits`.

**Remove** the `node_selector` block:
```hcl
node_selector = {
  "kubernetes.io/hostname" = "hestia"
}
```

**Remove** the GPU toleration block:
```hcl
toleration {
  key      = "nvidia.com/gpu"
  operator = "Exists"
  effect   = "NoSchedule"
}
```

- [ ] **Step 3: Add ResourceClaimTemplate via kubectl_manifest**

Add a new resource to `modules-k8s/ollama/main.tf`:

```hcl
resource "kubectl_manifest" "ollama_gpu_claim_template" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1beta1"
    kind       = "ResourceClaimTemplate"
    metadata   = { name = "ollama-gpu", namespace = var.namespace }
    spec = {
      spec = {
        devices = {
          requests = [{ name = "gpu", deviceClassName = "nvidia-gpu" }]
        }
      }
    }
  })
}
```

- [ ] **Step 4: Add resource_claims to the deployment pod spec**

The `kubernetes_deployment` provider block does not support `resource_claims` natively. Check if it's available:

```bash
terraform providers schema -json | python3 -c "
import json,sys
s=json.load(sys.stdin)
spec_block = s['provider_schemas']['registry.terraform.io/hashicorp/kubernetes']['resource_schemas']['kubernetes_deployment']['block']['block_types']['spec']['block']['block_types']['template']['block']['block_types']['spec']['block']
print('resource_claims' in spec_block.get('block_types', {}))
"
```

**If `True`:** add inside the pod `spec {}` block:
```hcl
resource_claims {
  name = "gpu"
  source {
    resource_claim_template_name = "ollama-gpu"
  }
}
```

**If `False`:** convert the `kubernetes_deployment.ollama` resource to a `kubectl_manifest` resource using the full deployment YAML. This is a larger change — use the existing deployment's current state as the base:
```bash
kubectl get deployment ollama -n default -o yaml
```
Strip `status`, `creationTimestamp`, `generation`, `resourceVersion`, `uid` fields. Add `resourceClaims` to the pod spec. Manage it as `kubectl_manifest "ollama"` instead.

- [ ] **Step 5: Also update versions.tf for the kubectl provider**

If not already present, ensure `modules-k8s/ollama/versions.tf` includes:
```hcl
kubectl = {
  source  = "alekc/kubectl"
  version = ">= 2.0.0"
}
```

- [ ] **Step 6: Plan**

```bash
terraform plan -target=module.k8s_ollama
```

Review: confirm `nvidia.com/gpu` removed from resource limits, `node_selector` removed, ResourceClaimTemplate added.

- [ ] **Step 7: Apply and verify**

```bash
terraform apply -target=module.k8s_ollama
```

```bash
kubectl get pod -n default -l app=ollama -o wide
kubectl logs -n default -l app=ollama --tail=20
```

Expected: pod Running on Hestia (DRA scheduler will still place it there since NVIDIA devices only exist on Hestia). Test GPU:

```bash
kubectl exec -n default deploy/ollama -- ollama run llama3.2:3b "Say hello"
```

- [ ] **Step 8: Commit**

```bash
git add modules-k8s/ollama/
git commit -m "feat(ollama): migrate GPU to DRA ResourceClaim (nvidia-gpu DeviceClass)"
```

---

## Task 14: Workload Migration — Plex

> **Gate:** Task 1 (CDI research) must be complete.
> **runtimeClassName verdict:** [VERDICT — fill in from Task 1]

**Files:**
- Modify: `modules-k8s/media-centre/main.tf`

- [ ] **Step 1: Read modules-k8s/media-centre/main.tf**

Read the full file. Focus on the Plex deployment's GPU-related config: `runtime_class_name`, `nvidia.com/gpu` limits, `node_selector`, any tolerations.

- [ ] **Step 2: Apply the same GPU migration as Task 13**

Make the same category of changes as Ollama:
- Apply Task 1 verdict to `runtime_class_name = "nvidia"`
- Remove `"nvidia.com/gpu" = "1"` from resource requests and limits
- Remove `node_selector` for `"kubernetes.io/hostname" = "hestia"`
- Remove any GPU toleration
- Add `kubectl_manifest "plex_gpu_claim_template"` with `deviceClassName = "nvidia-gpu"`
- Add `resource_claims` to the Plex pod spec (same approach as Task 13 Step 4)

- [ ] **Step 3: Plan**

```bash
terraform plan -target=module.k8s_media_centre
```

Review: GPU limits removed, node_selector removed, ResourceClaimTemplate added.

- [ ] **Step 4: Apply and verify**

```bash
terraform apply -target=module.k8s_media_centre
```

```bash
kubectl get pod -n default -l app=media-centre,component=plex -o wide
kubectl logs -n default -l app=media-centre,component=plex --tail=30
```

Verify hardware transcoding: start a transcode session in Plex and confirm the Plex dashboard shows hardware acceleration active.

- [ ] **Step 5: Commit**

```bash
git add modules-k8s/media-centre/
git commit -m "feat(plex): migrate GPU to DRA ResourceClaim (nvidia-gpu DeviceClass)"
```

---

## Task 15: Cleanup — Remove Old NVIDIA Device Plugin

> **Gate:** Tasks 13 and 14 must both be complete and verified healthy.

The `nvidia-device-plugin-daemonset` was not managed by Terraform — remove it directly.

- [ ] **Step 1: Confirm Ollama and Plex are healthy**

```bash
kubectl get pod -n default -l app=ollama
kubectl get pod -n default -l app=plex
```

Both must show `Running`. If either is not healthy, do not proceed — diagnose first.

- [ ] **Step 2: Delete the device plugin DaemonSet**

```bash
kubectl delete daemonset nvidia-device-plugin-daemonset -n kube-system
```

- [ ] **Step 3: Delete the device plugin ConfigMap**

```bash
kubectl delete configmap nvidia-device-plugin-config -n kube-system
```

- [ ] **Step 4: Verify nvidia.com/gpu capacity is gone**

```bash
kubectl get node hestia -o jsonpath='{.status.capacity}' | python3 -m json.tool | grep nvidia
```

Expected: no output — `nvidia.com/gpu` no longer advertised via the old plugin.

- [ ] **Step 5: Verify NVIDIA DRA ResourceSlice is present**

```bash
kubectl get resourceslice -o wide
```

Expected: at least one entry with `DRIVER=gpu.nvidia.com` from Hestia, and `rpi5.brmartin.co.uk` entries from Pi5 nodes that have devices.

- [ ] **Step 6: Commit**

```bash
git commit --allow-empty -m "chore: remove legacy nvidia-device-plugin (deleted via kubectl)"
```

---

## Task 16: Workload Migration — Iris

**Files:**
- Modify: `modules-k8s/iris/main.tf`

Iris is migrated last — it has no existing GPU dependency, so there's no risk of downtime during this step. This adds the `iris-transcode-hw` ResourceClaim so Iris can be scheduled to any node with hardware decode.

- [ ] **Step 1: Read modules-k8s/iris/main.tf**

Read the full file to understand the current deployment structure.

- [ ] **Step 2: Add ResourceClaimTemplate**

Add to `modules-k8s/iris/main.tf`:

```hcl
resource "kubectl_manifest" "iris_transcode_claim_template" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1beta1"
    kind       = "ResourceClaimTemplate"
    metadata   = { name = "iris-transcode-hw", namespace = var.namespace }
    spec = {
      spec = {
        devices = {
          requests = [{ name = "transcode", deviceClassName = "iris-transcode-hw" }]
        }
      }
    }
  })
}
```

- [ ] **Step 3: Add resource_claims to the Iris pod spec**

Apply the same check as Task 13 Step 4 for `resource_claims` provider support.

**If supported natively:** add inside the pod `spec {}` block of `kubernetes_deployment.iris`:
```hcl
resource_claims {
  name = "transcode"
  source {
    resource_claim_template_name = "iris-transcode-hw"
  }
}
```

**If not supported:** export the deployment as YAML and convert to `kubectl_manifest`, adding `resourceClaims` to the pod spec.

- [ ] **Step 4: Plan**

```bash
terraform plan -target=module.k8s_iris
```

Expected: only additive changes — ResourceClaimTemplate created, deployment updated with `resource_claims`. No volumes or mounts removed.

- [ ] **Step 5: Apply**

```bash
terraform apply -target=module.k8s_iris
```

- [ ] **Step 6: Verify scheduling and hardware detection**

```bash
kubectl get pod -n default -l app=iris,component=server -o wide
```

Note the node. Then:

```bash
kubectl logs -n default -l app=iris,component=server --tail=40 | grep -i "transcode\|hardware\|nvenc\|drm\|codec\|backend"
```

Expected: log line indicating detected hardware matching the node (NVIDIA on Hestia, DRM decoder on Pi5).

- [ ] **Step 7: Verify ResourceClaim is allocated**

```bash
kubectl get resourceclaim -n default
```

Expected: Iris's claim shows `ALLOCATED=true`.

- [ ] **Step 8: Commit**

```bash
git add modules-k8s/iris/
git commit -m "feat(iris): add DRA ResourceClaim for hardware transcode (iris-transcode-hw DeviceClass)"
```
