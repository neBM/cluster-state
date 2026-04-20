variable "namespace" {
  type    = string
  default = "default"
}

variable "hostname" {
  type    = string
  default = "langfuse.brmartin.co.uk"
}

variable "image_tag" {
  type    = string
  # renovate: datasource=docker depName=langfuse/langfuse
  default = "3"
}
