# nvidia-gpu — used by Ollama and Plex (Hestia only via NVIDIA DRA driver)
resource "kubectl_manifest" "nvidia_gpu" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1"
    kind       = "DeviceClass"
    metadata   = { name = "nvidia-gpu" }
    spec = {
      selectors = [{
        cel = { expression = "device.driver == \"gpu.nvidia.com\"" }
      }]
    }
  })
}

# hestia-gpu — shared static ResourceClaim for Ollama + Plex.
# Both pods reference this claim so the scheduler treats the GPU as shared between
# them (like the old device-plugin time-slicing) without requiring hardware timeslice
# policy support (unsupported on GTX 1070 Pascal via DRA TimeSlicing strategy).
resource "kubectl_manifest" "hestia_gpu_claim" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1"
    kind       = "ResourceClaim"
    metadata   = { name = "hestia-gpu", namespace = "default" }
    spec = {
      devices = {
        requests = [{
          name    = "gpu"
          exactly = { deviceClassName = "nvidia-gpu" }
        }]
      }
    }
  })
}

# iris-transcode-hw — used by Iris (any node: NVIDIA or Pi5 DRM)
resource "kubectl_manifest" "iris_transcode_hw" {
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1"
    kind       = "DeviceClass"
    metadata   = { name = "iris-transcode-hw" }
    spec = {
      selectors = [{
        cel = { expression = "device.driver in [\"gpu.nvidia.com\", \"rpi5.brmartin.co.uk\"]" }
      }]
    }
  })
}
