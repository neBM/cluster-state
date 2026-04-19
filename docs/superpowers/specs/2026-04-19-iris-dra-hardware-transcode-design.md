# Iris DRA Hardware Transcode Design

**Date:** 2026-04-19
**Status:** Approved

## Goal

Enable Iris to float freely across all three cluster nodes (1× NVIDIA GPU on Hestia, 2× Raspberry Pi 5 with V4L2/DRM decode) and automatically receive the correct hardware devices at scheduling time — without pinning, node selectors, or per-node pod specs. Simultaneously migrate all GPU workloads (Ollama, Plex) from the legacy NVIDIA device plugin to the DRA standard.

## Architecture

```
Hestia                              Pi5 nodes (×2)
  NVIDIA DRA driver (DaemonSet)       rpi5-dra-driver (DaemonSet — self-selecting)
  publishes ResourceSlice:              publishes ResourceSlice (if devices found):
    driver: gpu.nvidia.com                driver: rpi5.brmartin.co.uk
    vendor: nvidia                        vendor: raspberrypi
    model: <gpu model>                    codec.h264: true
    vram: <MB>                            codec.hevc: true
         \                                    /
          ──── DeviceClass: iris-transcode-hw ────
                 CEL: device.driver in ["gpu.nvidia.com", "rpi5.brmartin.co.uk"]
                          │
              Iris ResourceClaim (1 device, any matching class)
              Ollama ResourceClaim → DeviceClass: nvidia-gpu (Hestia only)
              Plex ResourceClaim   → DeviceClass: nvidia-gpu (Hestia only)
```

The DRA allocator places Iris on whichever of the three nodes has a free matching device. The allocated driver's CDI spec injects the correct device files into the container. Iris auto-detects available hardware at startup.

## Components

### 1. `drivers/rpi5-dra-driver/` — Custom Pi5 DRA Driver

New Go project in this repo, following the same structure as `drivers/seaweedfs-csi-driver/`.

**Package layout:**
```
cmd/rpi5-dra-driver/main.go     # entrypoint
pkg/
  driver/
    driver.go                   # DRA kubelet plugin gRPC interface
    discover.go                 # probes /dev/video* and /dev/dri/renderD*
    cdi.go                      # generates CDI spec for allocation
  resource/
    slice.go                    # builds and publishes ResourceSlice
Dockerfile
Makefile
go.mod                          # module: rpi5.brmartin.co.uk/rpi5-dra-driver
```

**Discovery (`discover.go`):**

Probes at startup and on SIGHUP. Looks for:
- `/dev/video11` — bcm2835-codec H.264 M2M encoder/decoder
- `/dev/video19` — rpivid HEVC stateless decoder
- `/dev/dri/renderD128` (or first available `renderD*`) — V3D render node

If none found: publishes empty `ResourceSlice`, gRPC server does not start, driver idles. No node labels required — the DaemonSet runs cluster-wide and is a no-op on non-Pi5 nodes (including future macOS nodes).

**ResourceSlice published (when devices found):**
```yaml
driver: rpi5.brmartin.co.uk
nodeName: <current node>
devices:
  - name: drm-decoder-0
    basic:
      attributes:
        vendor: {string: raspberrypi}
        codec.h264: {bool: true}
        codec.hevc: {bool: true}   # only if /dev/video19 present
```

**CDI spec on allocation:**

Injects into the container:
- `/dev/video11`
- `/dev/video19` (if present)
- `/dev/dri/renderD128` (or discovered renderD* node)

No environment variables injected — Iris auto-detects device presence.

**DaemonSet:** Runs on all nodes. RBAC grants `ResourceSlice` create/update/delete for `rpi5.brmartin.co.uk`. Image built and pushed to `registry.brmartin.co.uk/ben/rpi5-dra-driver:<sha>` via GitLab CI.

### 2. `modules-k8s/nvidia-dra-driver/` — NVIDIA DRA Driver Terraform Module

Deploys the official `k8s-dra-driver-gpu` via Helm. Must configure:
- Time-slicing with `replicas: 2` (preserves current Plex + Ollama concurrent GPU access)
- Self-selects to Hestia via NVIDIA device presence (no explicit node selector needed)

**Pre-implementation research gate:** Before writing Plex/Ollama migration tasks, verify whether `runtimeClassName: nvidia` on the Plex pod must be removed or changed when device injection moves to CDI. Document finding; update this spec if needed.

### 3. `modules-k8s/device-classes/` — Cluster-Wide DeviceClasses

New Terraform module, applied once. Defines:

| DeviceClass | CEL Selector | Consumers |
|---|---|---|
| `nvidia-gpu` | `device.driver == "gpu.nvidia.com"` | Ollama, Plex |
| `iris-transcode-hw` | `device.driver in ["gpu.nvidia.com", "rpi5.brmartin.co.uk"]` | Iris |

### 4. Workload Migration

**Iris (`modules-k8s/iris/`):**
- Add `ResourceClaimTemplate` (`iris-transcode-hw` DeviceClass, 1 device)
- Add `resource_claims` reference on pod template
- No changes to CPU/memory resources

**Ollama (`modules-k8s/ollama/`):**
- Remove `limits["nvidia.com/gpu"] = "1"`
- Add `ResourceClaim` referencing `nvidia-gpu` DeviceClass

**Plex (`modules-k8s/media-centre/`):**
- Remove `limits["nvidia.com/gpu"] = "1"`
- Remove or update `runtimeClassName: nvidia` (pending CDI research)
- Add `ResourceClaim` referencing `nvidia-gpu` DeviceClass

## Migration Sequence

Order matters to avoid GPU workload downtime:

1. Deploy `rpi5-dra-driver` DaemonSet — no impact on existing workloads
2. Deploy NVIDIA DRA driver — verify `ResourceSlice` appears for Hestia GPU
3. Research CDI + `runtimeClassName` question for Plex
4. Update Ollama → apply → verify healthy
5. Update Plex → apply → verify healthy
6. Remove `nvidia-device-plugin-daemonset` and `nvidia-device-plugin-config` ConfigMap
7. Update Iris → apply → verify hardware detected on scheduling node

Iris migration is last: it has no current GPU dependency, so it can wait until everything else is stable.

## Repository Changes Summary

| Path | Change |
|---|---|
| `drivers/rpi5-dra-driver/` | New Go project |
| `modules-k8s/nvidia-dra-driver/` | New Terraform module (Helm) |
| `modules-k8s/device-classes/` | New Terraform module |
| `modules-k8s/iris/main.tf` | Add ResourceClaim wiring |
| `modules-k8s/ollama/main.tf` | Migrate GPU resource to DRA |
| `modules-k8s/media-centre/main.tf` | Migrate GPU resource to DRA |
| `kubernetes.tf` | Add device-classes + nvidia-dra-driver module calls |
