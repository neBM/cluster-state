# NVIDIA DRA Driver for GPUs
# Chart: nvidia-dra-driver-gpu from https://helm.ngc.nvidia.com/nvidia
# Latest stable: 25.12.0 (CalVer: YY.MM.patch)
#
# NOTE: Time-slicing (gpu_time_slice_replicas) is NOT a Helm chart value.
# In DRA, GPU sharing is configured per-workload via DeviceClass selectors and
# ResourceClaim device config (device.config[].nvidia.com/sharing), not at
# driver install time. The variable is retained for documentation and future use.

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
