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
}
