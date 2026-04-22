variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "seaweedfs_image_tag" {
  description = "SeaweedFS image tag. Pinned to neBM fork build (v0.1.11 vidMap invalidation fix) until the fork PR lands upstream. Image must be sideloaded via drivers/seaweedfs-server/Makefile — not available on Docker Hub. See memory/project_seaweedfs_fork_pin_and_upstream_cleanup.md."
  type        = string
  # renovate: ignore — fork build, not a Docker Hub tag
  default = "4.18-nebm-d4cb0322"
}

variable "csi_driver_image_tag" {
  description = "SeaweedFS CSI driver image tag"
  type        = string
  default     = "v0.1.11"
}

variable "csi_mount_image_tag" {
  description = "SeaweedFS mount image tag"
  type        = string
  default     = "v0.1.11"
}

variable "consumer_recycler_image_tag" {
  description = "SeaweedFS consumer recycler image tag"
  type        = string
  default     = "v0.1.3"
}

variable "csi_provisioner_image_tag" {
  description = "CSI external-provisioner sidecar image tag"
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/sig-storage/csi-provisioner
  default = "v6.2.0"
}

variable "csi_attacher_image_tag" {
  description = "CSI external-attacher sidecar image tag"
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/sig-storage/csi-attacher
  default = "v4.11.0"
}

variable "csi_resizer_image_tag" {
  description = "CSI external-resizer sidecar image tag"
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/sig-storage/csi-resizer
  default = "v2.1.0"
}

variable "csi_node_registrar_image_tag" {
  description = "CSI node-driver-registrar sidecar image tag"
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/sig-storage/csi-node-driver-registrar
  default = "v2.16.0"
}

variable "csi_liveness_probe_image_tag" {
  description = "CSI liveness probe sidecar image tag"
  type        = string
  # renovate: datasource=docker depName=registry.k8s.io/sig-storage/livenessprobe
  default = "v2.18.0"
}

variable "master_replicas" {
  description = "Number of master replicas (Raft quorum)"
  type        = number
  default     = 3
}

variable "filer_replicas" {
  description = "Number of filer replicas"
  type        = number
  default     = 1
}

variable "volume_data_path" {
  description = "Host path for volume server data"
  type        = string
  default     = "/data/seaweedfs"
}

variable "master_data_path" {
  description = "Host path for master Raft journal"
  type        = string
  default     = "/var/lib/seaweedfs/master"
}

variable "filer_data_path" {
  description = "Host path for filer leveldb metadata"
  type        = string
  default     = "/var/lib/seaweedfs/filer"
}

variable "replication" {
  description = "Volume replication policy (e.g. 000 = no replication)"
  type        = string
  default     = "000"
}

variable "volume_node_hostnames" {
  description = "Node hostnames to run volume servers on"
  type        = list(string)
  default     = ["heracles", "nyx"]
}

variable "data_center" {
  description = "SeaweedFS dataCenter name"
  type        = string
  default     = "home"
}

variable "master_ingress_hostname" {
  description = "Hostname for SeaweedFS master UI"
  type        = string
  default     = ""
}

variable "filer_ingress_hostname" {
  description = "Hostname for SeaweedFS filer UI"
  type        = string
  default     = ""
}

variable "tls_secret_name" {
  description = "TLS certificate secret name"
  type        = string
  default     = "wildcard-brmartin-tls"
}
