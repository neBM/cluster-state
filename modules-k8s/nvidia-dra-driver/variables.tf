variable "chart_version" {
  description = "NVIDIA DRA driver for GPUs Helm chart version (nvidia-dra-driver-gpu)"
  type        = string
}

variable "gpu_time_slice_replicas" {
  description = "GPU time-slice replica count — informational only; DRA time-slicing is configured per-claim via DeviceClass/ResourceClaim, not at chart install time"
  type        = number
  default     = 2
}
