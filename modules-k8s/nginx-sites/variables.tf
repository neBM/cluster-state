variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "nginx_image_tag" {
  description = "Nginx container image tag"
  type        = string
  default     = "alpine"
}

variable "php_image_tag" {
  description = "PHP-FPM container image tag"
  type        = string
  default     = "8.5-fpm-alpine"
}
