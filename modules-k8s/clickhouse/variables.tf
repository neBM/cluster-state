variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "image_tag" {
  description = "ClickHouse server image tag"
  type        = string
  # renovate: datasource=docker depName=clickhouse/clickhouse-server
  default = "24.12-alpine"
}
