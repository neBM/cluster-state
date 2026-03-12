variable "namespace" {
  description = "Kubernetes namespace to deploy lldap into"
  type        = string
  default     = "default"
}

# renovate: datasource=docker depName=lldap/lldap
variable "image_tag" {
  description = "lldap container image tag"
  type        = string
  default     = "stable"
}

variable "hostname" {
  description = "Hostname for the lldap admin web UI"
  type        = string
  default     = "ldap.brmartin.co.uk"
}

variable "ldap_base_dn" {
  description = "LDAP base DN (e.g. dc=brmartin,dc=co,dc=uk)"
  type        = string
}


