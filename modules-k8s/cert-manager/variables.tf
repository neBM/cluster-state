variable "namespace" {
  description = "Namespace for the cert-manager installation"
  type        = string
  default     = "cert-manager"
}

variable "reloader_namespace" {
  description = "Namespace for the Reloader installation"
  type        = string
  default     = "reloader"
}

variable "acme_email" {
  description = "Email address used for ACME account registration"
  type        = string
  default     = "ben@brmartin.co.uk"
}

variable "cluster_issuer_name" {
  description = "Name of the ClusterIssuer resource"
  type        = string
  default     = "letsencrypt-cloudflare"
}

variable "root_domain" {
  description = "Base DNS zone used for the wildcard certificate"
  type        = string
  default     = "brmartin.co.uk"
}

variable "wildcard_secret_name" {
  description = "Name of the wildcard TLS secret created by cert-manager"
  type        = string
  default     = "wildcard-brmartin-tls"
}

variable "certificate_namespaces" {
  description = "Namespaces that should receive a wildcard TLS certificate"
  type        = list(string)
  default     = ["default", "kube-system"]
}
