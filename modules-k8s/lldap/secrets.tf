# lldap secrets must be created manually before applying this module:
#
#   kubectl create secret generic lldap-secrets -n default \
#     --from-literal=LLDAP_JWT_SECRET="$(openssl rand -hex 32)" \
#     --from-literal=LLDAP_KEY_SEED="$(openssl rand -hex 32)"
#
#   kubectl create secret generic lldap-db-secret -n default \
#     --from-literal=LLDAP_DATABASE_URL="postgres://lldap:<password>@192.168.1.10:5433/lldap?sslmode=disable"
#
#   kubectl create secret generic lldap-admin-secret -n default \
#     --from-literal=LLDAP_LDAP_USER_PASS="$(openssl rand -base64 24)"
#
#   kubectl create secret generic lldap-oidc-secret -n default \
#     --from-literal=LLDAP_OAUTH2__CLIENT_ID=lldap \
#     --from-literal=LLDAP_OAUTH2__CLIENT_SECRET="<keycloak client secret>"

data "kubernetes_secret" "lldap_secrets" {
  metadata {
    name      = "lldap-secrets"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "lldap_db" {
  metadata {
    name      = "lldap-db-secret"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "lldap_admin" {
  metadata {
    name      = "lldap-admin-secret"
    namespace = var.namespace
  }
}

# NOTE: lldap 0.6.2 does not support native OIDC/OAuth2 login. The lldap-oidc-secret
# and Keycloak client were created but lldap ignores the OAUTH2__ env vars entirely.
# The admin UI is protected by local admin credentials only.
# Keycloak LDAP User Federation (READ_ONLY) is configured separately in the Keycloak admin UI.
