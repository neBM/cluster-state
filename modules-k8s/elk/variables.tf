variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "es_image_tag" {
  description = "Elasticsearch container image tag"
  type        = string
  # renovate: datasource=docker depName=docker.elastic.co/elasticsearch/elasticsearch
  default = "9.2.3"
}

variable "kibana_image_tag" {
  description = "Kibana container image tag"
  type        = string
  # renovate: datasource=docker depName=docker.elastic.co/kibana/kibana
  default = "9.2.3"
}

variable "es_hostname" {
  description = "Hostname for Elasticsearch external access"
  type        = string
  default     = "es.brmartin.co.uk"
}

variable "kibana_hostname" {
  description = "Hostname for Kibana external access"
  type        = string
  default     = "kibana.brmartin.co.uk"
}

variable "es_data_path" {
  description = "Host path to Elasticsearch data directory (GlusterFS mount)"
  type        = string
  default     = "/storage/v/glusterfs_elasticsearch_data"
}

variable "es_memory_request" {
  description = "Memory request for Elasticsearch"
  type        = string
  default     = "4Gi"
}

variable "es_memory_limit" {
  description = "Memory limit for Elasticsearch"
  type        = string
  default     = "4Gi"
}

variable "es_cpu_request" {
  description = "CPU request for Elasticsearch"
  type        = string
  default     = "1000m"
}

variable "es_cpu_limit" {
  description = "CPU limit for Elasticsearch"
  type        = string
  default     = "2000m"
}

variable "es_java_opts" {
  description = "JVM options for Elasticsearch"
  type        = string
  default     = "-Xms2g -Xmx2g"
}

variable "kibana_memory_request" {
  description = "Memory request for Kibana"
  type        = string
  default     = "512Mi"
}

variable "kibana_memory_limit" {
  description = "Memory limit for Kibana"
  type        = string
  default     = "1Gi"
}

variable "kibana_cpu_request" {
  description = "CPU request for Kibana"
  type        = string
  default     = "250m"
}

variable "kibana_cpu_limit" {
  description = "CPU limit for Kibana"
  type        = string
  default     = "500m"
}

variable "tls_secret_name" {
  description = "TLS secret name for IngressRoutes"
  type        = string
  default     = "wildcard-brmartin-tls"
}

# =============================================================================
# Multi-Node ES Cluster Variables (009-es-multi-node-cluster)
# =============================================================================

variable "es_data_nodes" {
  description = "List of node hostnames for ES data nodes"
  type        = list(string)
  default     = ["hestia", "heracles"]
}

variable "es_tiebreaker_node" {
  description = "Node hostname for ES tiebreaker (voting-only)"
  type        = string
  default     = "nyx"
}

variable "es_data_memory_request" {
  description = "Memory request for ES data nodes"
  type        = string
  default     = "4Gi"
}

variable "es_data_memory_limit" {
  description = "Memory limit for ES data nodes"
  type        = string
  default     = "4Gi"
}

variable "es_data_cpu_request" {
  description = "CPU request for ES data nodes"
  type        = string
  default     = "500m"
}

variable "es_data_cpu_limit" {
  description = "CPU limit for ES data nodes"
  type        = string
  default     = "2000m"
}

variable "es_data_java_opts" {
  description = "JVM options for ES data nodes (heap should be ~50% of memory limit)"
  type        = string
  default     = "-Xms2g -Xmx2g"
}

variable "es_tiebreaker_memory_request" {
  description = "Memory request for ES tiebreaker node"
  type        = string
  default     = "1Gi"
}

variable "es_tiebreaker_memory_limit" {
  description = "Memory limit for ES tiebreaker node"
  type        = string
  default     = "1.5Gi"
}

variable "es_tiebreaker_cpu_request" {
  description = "CPU request for ES tiebreaker node"
  type        = string
  default     = "100m"
}

variable "es_tiebreaker_cpu_limit" {
  description = "CPU limit for ES tiebreaker node"
  type        = string
  default     = "500m"
}

variable "es_tiebreaker_java_opts" {
  description = "JVM options for ES tiebreaker node"
  type        = string
  default     = "-Xms512m -Xmx512m"
}

variable "es_data_storage_size" {
  description = "Storage size for ES data node PVCs"
  type        = string
  default     = "50Gi"
}
