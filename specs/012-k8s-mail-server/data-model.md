# Data Model: Kubernetes Mail Server Migration

**Feature**: 012-k8s-mail-server  
**Date**: 2026-03-11

---

## 1. Identity Entities (lldap)

These entities live in lldap and are the authoritative source of truth for mail account identity.

### User

The primary mail account holder. Stored in lldap as `inetOrgPerson`.

| Attribute | LDAP Attribute | Type | Required | Notes |
|-----------|----------------|------|----------|-------|
| Username | `uid` | string | Yes | Login identifier; must be unique within the base DN |
| Display name | `cn` | string | Yes | Full name shown in directory |
| First name | `givenName` | string | No | Optional |
| Last name | `sn` | string | Yes | Surname (required by `inetOrgPerson` schema) |
| Email address | `mail` | string | Yes | Primary mail address (e.g. `ben@brmartin.co.uk`) |
| Password | internal | argon2 hash | Yes | Never exposed via LDAP; verified only via bind |

**LDAP DN pattern**: `uid=<username>,ou=people,dc=brmartin,dc=co,dc=uk`

**Lifecycle operations** (performed via lldap web UI, authenticated by Keycloak OIDC):
- Create: Admin creates user in lldap → account immediately usable via LDAP bind
- Disable: Delete user from lldap or remove from mail-users group → auth fails
- Password reset: Admin sets new password in lldap

### Group

Used to scope which lldap users are permitted to use mail services. Stored as `groupOfUniqueNames`.

| Attribute | LDAP Attribute | Type | Notes |
|-----------|----------------|------|-------|
| Group name | `cn` | string | e.g. `mail-users` |
| Members | `member` | DN list | DNs of User objects in this group |

**DN pattern**: `cn=<group-name>,ou=groups,dc=brmartin,dc=co,dc=uk`

Mail components filter users by group membership to prevent non-mail users from appearing in mail lookups:
```
user_filter = (&(objectClass=inetOrgPerson)(memberOf=cn=mail-users,ou=groups,dc=brmartin,dc=co,dc=uk))
```

---

## 2. Mail Configuration Entities

These entities control mail routing and are managed as Kubernetes ConfigMaps and Secrets (not in a database).

### MailDomain

Defines a domain for which the system accepts and sends email. Managed as Postfix `virtual_mailbox_domains` configuration.

| Field | Storage | Notes |
|-------|---------|-------|
| Domain name | ConfigMap (Postfix) | e.g. `brmartin.co.uk`, `martinilink.co.uk` |
| DKIM key pair | Kubernetes Secret | RSA private key per domain; mounted into Rspamd |
| DKIM selector | ConfigMap (Rspamd) | e.g. `dkim` (migrated from mailcow) |

### MailAlias

Maps one email address to one or more delivery targets. Managed as Postfix `virtual_alias_maps`.

| Field | Storage | Notes |
|-------|---------|-------|
| Alias address | ConfigMap (Postfix) | e.g. `ben@martinilink.co.uk` |
| Target address(es) | ConfigMap (Postfix) | e.g. `ben@brmartin.co.uk` |

### MailRelayHost

Optional upstream SMTP relay configuration for outbound mail. Managed as Postfix `relayhost` in ConfigMap.

---

## 3. Mail Storage Entities

These entities live on persistent storage and represent the user's actual mail data.

### Mailbox

A user's persistent email storage. Stored in **Maildir format** on the Dovecot PVC.

| Field | Notes |
|-------|-------|
| Path | `/var/mail/<domain>/<username>/Maildir/` |
| Folders | `cur/`, `new/`, `tmp/`, `.Archive/`, `.Drafts/`, `.Junk/`, `.Sent/`, `.Trash/` |
| Folder index | Stored in emptyDir at `/var/indexes/<domain>/<username>/` (rebuilt on pod restart) |
| Sieve filters | `/var/mail/<domain>/<username>/sieve/` |

**Ownership**: All Maildir files owned by `vmail` user (uid 5000, gid 5000) inside the Dovecot container.

### MessageQueue

Postfix's in-flight message queue. Stored on the Postfix PVC.

| Field | Notes |
|-------|-------|
| Path | `/var/spool/postfix/` (standard Postfix queue layout) |
| Persistence | Must survive pod restarts to avoid message loss |

---

## 4. Kubernetes Resource Relationships

```
┌─────────────────────────────────────────────────────────────────────┐
│  modules-k8s/lldap/                                                 │
│                                                                     │
│  kubernetes_deployment.lldap ──────── kubernetes_service.lldap     │
│    └─ env: KC_DB_URL → lldap-db-secret                             │
│    └─ env: LLDAP_JWT_SECRET → lldap-secrets                        │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  modules-k8s/mail/                                                  │
│                                                                     │
│  kubernetes_statefulset.postfix                                     │
│    └─ hostPort 25/465/587                                           │
│    └─ nodeSelector: hestia                                          │
│    └─ configmap: postfix-config (virtual domains, alias maps)      │
│    └─ secret: mail-tls (wildcard cert)                              │
│    └─ pvc: postfix-spool (queue)                                    │
│    └─ Service: postfix (ClusterIP for LMTP coordination)            │
│                                                                     │
│  kubernetes_statefulset.dovecot                                     │
│    └─ hostPort 143/993/110/995/4190                                 │
│    └─ nodeSelector: hestia                                          │
│    └─ configmap: dovecot-ldap (LDAP bind config)                   │
│    └─ secret: mail-tls (wildcard cert)                              │
│    └─ pvc: dovecot-mailboxes (Maildir data)                        │
│    └─ emptyDir: dovecot-indexes (rebuilt on restart)               │
│    └─ Service: dovecot (ClusterIP for Postfix LMTP + SASL)         │
│                                                                     │
│  kubernetes_deployment.rspamd                                       │
│    └─ configmap: rspamd-config (milter binding, Redis, DKIM)       │
│    └─ secret: dkim-keys (per-domain RSA private keys)              │
│    └─ pvc: rspamd-data (bayes, greylisting state)                  │
│    └─ Service: rspamd (ClusterIP :11332 for Postfix milter)        │
│                                                                     │
│  kubernetes_deployment.mail-redis                                   │
│    └─ emptyDir (ephemeral; learned data retrainable)               │
│    └─ Service: mail-redis (ClusterIP :6379)                        │
│                                                                     │
│  kubernetes_deployment.sogo                                         │
│    └─ configmap: sogo-config (LDAP, IMAP, SMTP, PostgreSQL)        │
│    └─ secret: sogo-db-secret (PostgreSQL credentials)              │
│    └─ Service: sogo (ClusterIP :20000)                             │
│    └─ IngressRoute: mail.brmartin.co.uk → sogo:20000               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Secret Inventory

| Secret Name | Namespace | Contents | Source |
|-------------|-----------|----------|--------|
| `lldap-secrets` | default | `LLDAP_JWT_SECRET`, `LLDAP_KEY_SEED` | Generated |
| `lldap-db-secret` | default | `LLDAP_DATABASE_URL` (PostgreSQL DSN) | Generated |
| `mail-tls` | default | `tls.crt`, `tls.key` (wildcard cert) | Copy of `traefik/wildcard-brmartin-tls` |
| `dkim-keys` | default | `brmartin.co.uk.dkim.key`, `martinilink.co.uk.dkim.key` | Extracted from mailcow Redis |
| `postfix-ldap-secret` | default | LDAP bind password for Postfix LDAP lookups | Generated |
| `dovecot-ldap-secret` | default | LDAP bind password for Dovecot auth | Generated |
| `sogo-db-secret` | default | PostgreSQL DSN for SoGO | Generated |
| `rspamd-password` | default | Rspamd controller password (web UI) | Generated |

---

## 6. Network Topology

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| External MTA | Postfix (hostPort) | 25 | TCP/SMTP | Inbound mail delivery |
| Mail client | Postfix (hostPort) | 587 | TCP/SMTP+STARTTLS | Authenticated submission |
| Mail client | Postfix (hostPort) | 465 | TCP/SMTPS | Authenticated submission (implicit TLS) |
| Mail client | Dovecot (hostPort) | 143 | TCP/IMAP+STARTTLS | Mail retrieval |
| Mail client | Dovecot (hostPort) | 993 | TCP/IMAPS | Mail retrieval (implicit TLS) |
| Mail client | Dovecot (hostPort) | 110 | TCP/POP3+STARTTLS | Mail retrieval |
| Mail client | Dovecot (hostPort) | 995 | TCP/POP3S | Mail retrieval (implicit TLS) |
| Mail client | Dovecot (hostPort) | 4190 | TCP/Sieve | Client-side filter management |
| Browser | Traefik (443) → SoGO | 20000 | HTTP | Webmail |
| Postfix | Rspamd (ClusterIP) | 11332 | TCP/milter | Spam check + DKIM sign |
| Postfix | Dovecot (ClusterIP) | 24 | TCP/LMTP | Local mail delivery |
| Postfix | Dovecot (ClusterIP) | 12345 | TCP/SASL | SMTP auth delegation |
| Dovecot | lldap (ClusterIP) | 3890 | TCP/LDAP | User authentication (bind) |
| Postfix | lldap (ClusterIP) | 3890 | TCP/LDAP | Virtual domain/mailbox lookup |
| SoGO | lldap (ClusterIP) | 3890 | TCP/LDAP | User authentication + directory |
| Rspamd | mail-redis (ClusterIP) | 6379 | TCP/Redis | Bayes, rate limiting, greylisting |
| Keycloak | lldap (ClusterIP) | 3890 | TCP/LDAP | User federation (read-only) |
