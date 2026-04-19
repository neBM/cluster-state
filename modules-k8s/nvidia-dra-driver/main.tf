resource "kubernetes_labels" "hestia_gpu" {
  api_version = "v1"
  kind        = "Node"
  metadata {
    name = "hestia"
  }
  labels = {
    "nvidia.com/gpu.present" = "true"
  }
}

resource "helm_release" "nvidia_dra_driver" {
  name             = "nvidia-dra-driver-gpu"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "nvidia-dra-driver-gpu"
  version          = var.chart_version
  namespace        = "nvidia-dra-driver"
  create_namespace = true

  # Enable GPU kubelet plugin (disabled by default upstream; required for workloads)
  set {
    name  = "resources.gpus.enabled"
    value = "true"
  }

  # Chart requires explicit opt-in when resources.gpus.enabled=true to confirm
  # the legacy nvidia-device-plugin has been removed from the cluster.
  set {
    name  = "gpuResourcesEnabledOverride"
    value = "true"
  }

}
