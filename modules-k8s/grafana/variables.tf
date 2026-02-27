variable "app_name" {
  type        = string
  description = "Application name"
  default     = "grafana"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace"
  default     = "default"
}

variable "image_registry" {
  type        = string
  description = "Container image registry"
  default     = "grafana"
}

variable "image_name" {
  type        = string
  description = "Container image name"
  default     = "grafana"
}

variable "image_tag" {
  type        = string
  description = "Container image tag"
  default     = "11.4.0"
}

variable "replicas" {
  type        = number
  description = "Number of replicas"
  default     = 1
}

variable "storage_size" {
  type        = string
  description = "Storage size for Grafana data"
  default     = "1Gi"
}

variable "storage_class" {
  type        = string
  description = "Storage class for persistent volume"
  default     = "local-path"
}

variable "cpu_request" {
  type        = string
  description = "CPU request"
  default     = "100m"
}

variable "cpu_limit" {
  type        = string
  description = "CPU limit"
  default     = "500m"
}

variable "memory_request" {
  type        = string
  description = "Memory request"
  default     = "325Mi"
}

variable "memory_limit" {
  type        = string
  description = "Memory limit"
  default     = "512Mi"
}

variable "traefik_middlewares" {
  type        = list(string)
  description = "Traefik middlewares to apply"
  default     = []
}

variable "tls_secret_name" {
  type        = string
  description = "TLS certificate secret name"
  default     = "wildcard-brmartin-tls"
}

variable "ingress_hostname" {
  type        = string
  description = "Ingress hostname"
  default     = "grafana.brmartin.co.uk"
}

variable "keycloak_url" {
  type        = string
  description = "Keycloak base URL"
  default     = "https://sso.brmartin.co.uk"
}

variable "keycloak_realm" {
  type        = string
  description = "Keycloak realm"
  default     = "prod"
}

variable "keycloak_client_id" {
  type        = string
  description = "Keycloak client ID"
  default     = "grafana"
}

variable "prometheus_url" {
  type        = string
  description = "Prometheus URL for datasource"
  default     = "http://prometheus.default.svc.cluster.local:9090"
}

variable "vault_secret_path" {
  type        = string
  description = "Vault secret path for Grafana credentials"
  default     = "nomad/default/grafana"
}