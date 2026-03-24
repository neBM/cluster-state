# Mail stack secrets must be created manually before applying this module.
#
# ─── Cluster app SMTP service accounts ────────────────────────────────────────
# Each cluster app that sends mail gets a dedicated lldap service account in the
# mail-senders group (SMTP submission only — no IMAP). All apps send as:
#   From: services@brmartin.co.uk
#   SMTP: mail.brmartin.co.uk:587  (CoreDNS rewrites to postfix.default.svc.cluster.local)
#
# One-time bootstrap (run after first deploy):
#
#   LLDAP_POD=$(kubectl get pod -n default -l app=lldap -o name | head -1)
#   kubectl port-forward -n default svc/lldap 17170:17170 &
#   ADMIN_PW=$(kubectl get secret lldap-admin-secret -n default -o jsonpath='{.data.LLDAP_LDAP_USER_PASS}' | base64 -d)
#   TOKEN=$(curl -s -X POST http://localhost:17170/auth/simple/login \
#     -H 'Content-Type: application/json' \
#     -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PW\"}" \
#     | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
#
#   # Create mail-senders group
#   SENDERS_GID=$(curl -s -X POST http://localhost:17170/api/graphql \
#     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#     -d '{"query":"mutation { createGroup(name: \"mail-senders\") { id } }"}' \
#     | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['createGroup']['id'])")
#
#   # For each app in: grafana vaultwarden nextcloud gitlab keycloak
#   for APP in grafana vaultwarden nextcloud gitlab keycloak; do
#     PW=$(openssl rand -base64 24)
#     # Create user
#     curl -s -X POST http://localhost:17170/api/graphql \
#       -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#       -d "{\"query\":\"mutation { createUser(user: { id: \\\"svc-$APP\\\", email: \\\"svc-$APP@brmartin.co.uk\\\", displayName: \\\"$APP SMTP\\\" }) { id } }\"}"
#     # Add to mail-senders
#     curl -s -X POST http://localhost:17170/api/graphql \
#       -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#       -d "{\"query\":\"mutation { addUserToGroup(userId: \\\"svc-$APP\\\", groupId: $SENDERS_GID) { ok } }\"}"
#     # Set password
#     kubectl exec -n default $LLDAP_POD -- /app/lldap_set_password \
#       --base-url http://localhost:17170 --admin-username admin \
#       --admin-password "$ADMIN_PW" --username "svc-$APP" --password "$PW"
#     # Create K8s secret
#     kubectl create secret generic "${APP}-smtp-secret" -n default \
#       --from-literal=SMTP_USERNAME="svc-$APP" \
#       --from-literal=SMTP_PASSWORD="$PW"
#     echo "Created svc-$APP / ${APP}-smtp-secret"
#   done
#   kill %1  # stop port-forward
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
