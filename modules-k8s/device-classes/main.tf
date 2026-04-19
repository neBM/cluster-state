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
