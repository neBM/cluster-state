variable "namespace" {
  description = "Kubernetes namespace for Elastic Agent"
  type        = string
  default     = "elastic-system"
}

variable "elastic_agent_image" {
  description = "Elastic Agent container image name"
  type        = string
  default     = "docker.elastic.co/elastic-agent/elastic-agent"
}

variable "elastic_agent_tag" {
  description = "Elastic Agent container image tag"
  type        = string
  # renovate: datasource=docker depName=docker.elastic.co/elastic-agent/elastic-agent
  default = "9.3.0"
}

variable "fleet_url" {
  description = "Fleet Server URL for enrollment"
  type        = string
}

variable "fleet_insecure" {
  description = "Allow insecure connection to Fleet Server"
  type        = bool
  default     = false
}

variable "enrollment_token_secret_name" {
  description = "Name of the K8s secret containing the Fleet enrollment token"
  type        = string
  default     = "elastic-agent-enrollment"
}

variable "enrollment_token_secret_key" {
  description = "Key in the secret containing the enrollment token"
  type        = string
  default     = "token"
}

variable "cpu_request" {
  description = "CPU request for Elastic Agent"
  type        = string
  default     = "100m"
}

variable "memory_request" {
  description = "Memory request for Elastic Agent"
  type        = string
  default     = "500Mi"
}

variable "memory_limit" {
  description = "Memory limit for Elastic Agent"
  type        = string
  default     = "1Gi"
}
