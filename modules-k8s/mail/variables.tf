variable "namespace" {
  description = "Kubernetes namespace to deploy the mail stack into"
  type        = string
  default     = "default"
}

# renovate: datasource=docker depName=tozd/postfix
variable "image_tag_postfix" {
  description = "Container image tag for tozd/postfix (ubuntu-noble = Postfix 3.8)"
  type        = string
  default     = "ubuntu-noble"
}

# renovate: datasource=docker depName=dovecot/dovecot
variable "image_tag_dovecot" {
  description = "Container image tag for dovecot/dovecot"
  type        = string
  default     = "2.3-latest"
}

# renovate: datasource=docker depName=rspamd/rspamd
variable "image_tag_rspamd" {
  description = "Container image tag for rspamd/rspamd"
  type        = string
  default     = "latest"
}

# renovate: datasource=docker depName=redis
variable "image_tag_redis" {
  description = "Container image tag for redis"
  type        = string
  default     = "7-alpine"
}

# renovate: datasource=docker depName=salvoxia/sogo
variable "image_tag_sogo" {
  description = "Container image tag for salvoxia/sogo"
  type        = string
  default     = "latest"
}

variable "hostname" {
  description = "Hostname for SoGO webmail"
  type        = string
  default     = "mail.brmartin.co.uk"
}

variable "lldap_host" {
  description = "ClusterDNS hostname for the lldap LDAP service"
  type        = string
  default     = "lldap.default.svc.cluster.local"
}

variable "ldap_base_dn" {
  description = "LDAP base DN (e.g. dc=brmartin,dc=co,dc=uk)"
  type        = string
}

variable "domains" {
  description = "List of mail domains accepted by Postfix"
  type        = list(string)
  default     = ["brmartin.co.uk", "martinilink.co.uk"]
}

variable "db_host" {
  description = "External PostgreSQL host"
  type        = string
  default     = "192.168.1.10"
}

variable "db_port" {
  description = "External PostgreSQL port"
  type        = number
  default     = 5433
}

variable "sogo_db_name" {
  description = "PostgreSQL database name for SoGO"
  type        = string
  default     = "sogo"
}

variable "sogo_db_user" {
  description = "PostgreSQL user for SoGO"
  type        = string
  default     = "sogo"
}

