# Mail stack secrets must be created manually before applying this module.
#
# Postfix outbound relay (Mailgun):
#   kubectl create secret generic postfix-relay-secret -n default \
#     --from-literal=RELAY_HOST='[smtp.mailgun.org]:587' \
#     --from-literal=RELAY_USERNAME='postmaster@mg.brmartin.co.uk' \
#     --from-literal=RELAY_PASSWORD='<mailgun-smtp-password>'
#
# DKIM private keys (extracted from mailcow Redis):
#   kubectl create secret generic dkim-keys -n default \
#     --from-file=brmartin.co.uk.dkim.key=<(redis-cli HGET DKIM_PRIV_KEYS dkim.brmartin.co.uk) \
#     --from-file=martinilink.co.uk.dkim.key=<(redis-cli HGET DKIM_PRIV_KEYS dkim.martinilink.co.uk)
#
# Postfix LDAP bind password:
#   kubectl create secret generic postfix-ldap-secret -n default \
#     --from-literal=LDAP_BIND_PW="<password>"
#
# Dovecot LDAP bind password:
#   kubectl create secret generic dovecot-ldap-secret -n default \
#     --from-literal=LDAP_BIND_PW="<password>"
#
# SoGO PostgreSQL DSN:
#   kubectl create secret generic sogo-db-secret -n default \
#     --from-literal=SOGO_DB_URL="postgres://sogo:<password>@192.168.1.10:5433/sogo?sslmode=disable"
#
# SoGO LDAP bind password:
#   kubectl create secret generic sogo-ldap-secret -n default \
#     --from-literal=LDAP_BIND_PW="<password>"
#
# Wildcard TLS cert (copy from traefik namespace):
#   kubectl get secret wildcard-brmartin-tls -n traefik -o yaml \
#     | sed 's/namespace: traefik/namespace: default/' \
#     | kubectl apply -f - && \
#   kubectl get secret wildcard-brmartin-tls -n default -o json \
#     | jq '.metadata.name = "mail-tls"' \
#     | kubectl apply -f -

data "kubernetes_secret" "dkim_keys" {
  metadata {
    name      = "dkim-keys"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "postfix_relay" {
  metadata {
    name      = "postfix-relay-secret"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "postfix_ldap" {
  metadata {
    name      = "postfix-ldap-secret"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "dovecot_ldap" {
  metadata {
    name      = "dovecot-ldap-secret"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "sogo_db" {
  metadata {
    name      = "sogo-db-secret"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "sogo_ldap" {
  metadata {
    name      = "sogo-ldap-secret"
    namespace = var.namespace
  }
}
