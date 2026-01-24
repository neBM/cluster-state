variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "es_image_tag" {
  description = "Elasticsearch container image tag"
  type        = string
  default     = "9.2.3"
}

variable "kibana_image_tag" {
  description = "Kibana container image tag"
  type        = string
  default     = "9.2.3"
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
