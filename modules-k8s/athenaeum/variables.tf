variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "backend_image" {
  description = "Athenaeum backend container image"
  type        = string
  default     = "registry.brmartin.co.uk/ben/athenaeum/backend:6a28d5c4"
}

variable "frontend_image" {
  description = "Athenaeum frontend container image"
  type        = string
  default     = "registry.brmartin.co.uk/ben/athenaeum/frontend:6a28d5c4"
}

variable "domain" {
  description = "External domain for Athenaeum"
  type        = string
  default     = "athenaeum.brmartin.co.uk"
}

variable "redis_image" {
  description = "Redis container image"
  type        = string
  default     = "redis:7-alpine"
}

variable "keycloak_url" {
  description = "Keycloak server URL"
  type        = string
  default     = "https://sso.brmartin.co.uk"
}

variable "keycloak_realm" {
  description = "Keycloak realm name"
  type        = string
  default     = "prod"
}

variable "keycloak_client_id" {
  description = "Keycloak client ID for frontend (public client)"
  type        = string
  default     = "athenaeum-ui"
}

variable "ollama_url" {
  description = "Ollama LLM service URL for fact extraction and response assembly"
  type        = string
  default     = "http://ollama.default.svc.cluster.local:11434"
}

variable "ollama_model" {
  description = "Ollama model name for fact extraction"
  type        = string
  default     = "qwen2.5:3b"
}
