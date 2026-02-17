variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

# Hostnames
variable "synapse_hostname" {
  description = "Hostname for Synapse homeserver"
  type        = string
  default     = "matrix.brmartin.co.uk"
}

variable "mas_hostname" {
  description = "Hostname for Matrix Authentication Service"
  type        = string
  default     = "mas.brmartin.co.uk"
}

variable "element_hostname" {
  description = "Hostname for Element web client"
  type        = string
  default     = "element.brmartin.co.uk"
}

variable "cinny_hostname" {
  description = "Hostname for Cinny web client"
  type        = string
  default     = "cinny.brmartin.co.uk"
}

variable "well_known_hostname" {
  description = "Hostname for well-known endpoints (main domain)"
  type        = string
  default     = "brmartin.co.uk"
}

# =============================================================================
# Container Images
# =============================================================================

variable "synapse_image" {
  description = "Synapse Docker image name"
  type        = string
  default     = "ghcr.io/element-hq/synapse"
}

variable "synapse_tag" {
  description = "Synapse Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/element-hq/synapse
  default = "v1.147.1"
}

variable "mas_image" {
  description = "Matrix Authentication Service Docker image name"
  type        = string
  default     = "ghcr.io/element-hq/matrix-authentication-service"
}

variable "mas_tag" {
  description = "Matrix Authentication Service Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/element-hq/matrix-authentication-service
  default = "1.11.0"
}

variable "whatsapp_image" {
  description = "WhatsApp bridge Docker image name"
  type        = string
  default     = "dock.mau.dev/mautrix/whatsapp"
}

variable "whatsapp_tag" {
  description = "WhatsApp bridge Docker image tag"
  type        = string
  # renovate: datasource=docker depName=dock.mau.dev/mautrix/whatsapp
  default = "v0.2602.0"
}

variable "element_image" {
  description = "Element web Docker image name"
  type        = string
  default     = "docker.io/vectorim/element-web"
}

variable "element_tag" {
  description = "Element web Docker image tag"
  type        = string
  # renovate: datasource=docker depName=docker.io/vectorim/element-web
  default = "v1.12.10"
}

variable "cinny_image" {
  description = "Cinny Docker image name"
  type        = string
  default     = "ghcr.io/cinnyapp/cinny"
}

variable "cinny_tag" {
  description = "Cinny Docker image tag"
  type        = string
  # renovate: datasource=docker depName=ghcr.io/cinnyapp/cinny
  default = "v4.10.3"
}

variable "nginx_image" {
  description = "Nginx Docker image name"
  type        = string
  default     = "docker.io/library/nginx"
}

variable "nginx_tag" {
  description = "Nginx Docker image tag"
  type        = string
  # renovate: datasource=docker depName=docker.io/library/nginx
  default = "1.29.5-alpine"
}

# Database configuration
variable "db_host" {
  description = "PostgreSQL host"
  type        = string
  default     = "192.168.1.10"
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = string
  default     = "5433"
}

variable "synapse_db_name" {
  description = "Synapse database name"
  type        = string
  default     = "synapse"
}

variable "synapse_db_user" {
  description = "Synapse database user"
  type        = string
  default     = "synapse_user"
}

variable "mas_db_name" {
  description = "MAS database name"
  type        = string
  default     = "mas"
}

variable "mas_db_user" {
  description = "MAS database user"
  type        = string
  default     = "mas_user"
}

# Server name (Matrix federation identity)
variable "server_name" {
  description = "Matrix server name for federation"
  type        = string
  default     = "brmartin.co.uk"
}

# SMTP configuration
variable "smtp_host" {
  description = "SMTP server hostname"
  type        = string
  default     = "mail.brmartin.co.uk"
}

variable "smtp_port" {
  description = "SMTP server port"
  type        = string
  default     = "587"
}

variable "smtp_user" {
  description = "SMTP username"
  type        = string
  default     = "ben@brmartin.co.uk"
}

variable "smtp_from" {
  description = "Email from address"
  type        = string
  default     = "services@brmartin.co.uk"
}

# TURN server
variable "turn_uri" {
  description = "TURN server URI"
  type        = string
  default     = "turn:turn.brmartin.co.uk"
}
