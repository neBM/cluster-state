variable "nomad_address" {
  description = "Address of the Nomad server"
  type        = string
  default     = "http://hestia.lan:4646"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}
