# Inter-Service Contracts: Mail Stack

**Feature**: 012-k8s-mail-server  
**Date**: 2026-03-11

These contracts define the interface between each component pair. They are binding for implementation.

---

## Contract 1: Postfix → Rspamd (Milter)

**Protocol**: Milter (mail filter protocol v6)  
**Transport**: TCP  
**Address**: `rspamd.default.svc.cluster.local:11332`  
**Direction**: Postfix calls Rspamd for every inbound and outbound message

**Postfix configuration** (`main.cf`):
```
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:rspamd:11332
non_smtpd_milters = inet:rspamd:11332
milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}
```

**Rspamd binding** (`local.d/worker-proxy.inc`):
```
upstream "local" {
  self_scan = yes;
}
bind_socket = "*:11332";
```

**Failure mode**: `milter_default_action = accept` — if Rspamd is unreachable, mail passes through unfiltered. This prevents mail loss at the cost of reduced spam protection.

---

## Contract 2: Postfix → Dovecot (LMTP delivery)

**Protocol**: LMTP (Local Mail Transfer Protocol)  
**Transport**: TCP  
**Address**: `dovecot.default.svc.cluster.local:24`  
**Direction**: Postfix delivers accepted mail to Dovecot for mailbox storage

**Postfix configuration** (`main.cf`):
```
virtual_transport = lmtp:inet:dovecot:24
```

**Dovecot LMTP listener** (`10-master.conf`):
```
service lmtp {
  inet_listener lmtp {
    address = 0.0.0.0
    port = 24
  }
}
```

**Note**: Unix sockets MUST NOT be used between Postfix and Dovecot pods (Constitution: no Unix sockets on network storage; inter-pod sockets require a shared volume). TCP is mandatory.

---

## Contract 3: Postfix → Dovecot (SASL authentication)

**Protocol**: Dovecot SASL (over TCP)  
**Transport**: TCP  
**Address**: `dovecot.default.svc.cluster.local:12345`  
**Direction**: Postfix delegates SMTP AUTH to Dovecot for submission auth

**Postfix configuration** (`main.cf`):
```
smtpd_sasl_type = dovecot
smtpd_sasl_path = inet:dovecot:12345
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_tls_security_options = noanonymous
```

**Dovecot SASL listener** (`10-master.conf`):
```
service auth {
  inet_listener {
    port = 12345
  }
}
```

---

## Contract 4: Dovecot → lldap (LDAP Authentication)

**Protocol**: LDAP v3  
**Transport**: TCP (plaintext within cluster — acceptable since within K8s network)  
**Address**: `lldap.default.svc.cluster.local:3890`  
**Direction**: Dovecot queries lldap to verify user credentials and look up mailbox paths

**Critical requirement**: `auth_bind = yes` — lldap does not expose `userPassword` hashes. Dovecot must use bind-auth mode (attempt LDAP bind with user's credentials; success/failure is the auth result).

**Dovecot LDAP configuration** (`dovecot-ldap.conf`):
```
hosts = lldap:3890
dn = uid=dovecot,ou=people,dc=brmartin,dc=co,dc=uk
dnpass = <from dovecot-ldap-secret>
auth_bind = yes
auth_bind_userdn = uid=%n,ou=people,dc=brmartin,dc=co,dc=uk
base = ou=people,dc=brmartin,dc=co,dc=uk
scope = subtree

# Password lookup (bind-mode)
pass_filter = (&(objectClass=inetOrgPerson)(uid=%n))

# User attributes (mailbox path derivation)
user_filter = (&(objectClass=inetOrgPerson)(uid=%n))
user_attrs = mail=user, =uid=5000, =gid=5000, =home=/var/mail/%Ld/%Ln, =mail=maildir:~/Maildir
```

**lldap service account**: A dedicated read-only lldap user (`uid=dovecot,ou=people,...`) is used for the initial bind to look up the user before the bind-auth. This account must be provisioned in lldap.

---

## Contract 5: Postfix → lldap (Virtual Mailbox Lookup)

**Protocol**: LDAP v3  
**Transport**: TCP  
**Address**: `lldap.default.svc.cluster.local:3890`  
**Direction**: Postfix queries lldap to resolve virtual domains and mailbox addresses

**Postfix LDAP maps** (`main.cf`):
```
virtual_mailbox_domains = ldap:/etc/postfix/ldap-domains.cf
virtual_mailbox_maps = ldap:/etc/postfix/ldap-mailboxes.cf
virtual_alias_maps = ldap:/etc/postfix/ldap-aliases.cf
```

**`ldap-mailboxes.cf`** (users with a `mail` attribute in lldap):
```
server_host = ldap://lldap:3890
bind = yes
bind_dn = uid=postfix,ou=people,dc=brmartin,dc=co,dc=uk
bind_pw = <from postfix-ldap-secret>
search_base = ou=people,dc=brmartin,dc=co,dc=uk
query_filter = (&(objectClass=inetOrgPerson)(mail=%s))
result_attribute = mail
```

**`ldap-domains.cf`** (virtual domain lookup returns non-empty for accepted domains):
```
# Static domain list (no LDAP query needed for 2 domains; use hash: map)
# Define virtual_mailbox_domains as a static list in main.cf instead:
# virtual_mailbox_domains = brmartin.co.uk, martinilink.co.uk
```

**lldap service account**: A dedicated read-only account (`uid=postfix,ou=people,...`) for Postfix LDAP lookups.

---

## Contract 6: SoGO → lldap (User Authentication + Directory)

**Protocol**: LDAP v3  
**Transport**: TCP  
**Address**: `lldap.default.svc.cluster.local:3890`  
**Direction**: SoGO queries lldap to authenticate users and look up identities

**SoGO `sogo.conf`** (user source entry):
```
SOGoUserSources = (
  {
    type = ldap;
    CNFieldName = cn;
    IDFieldName = uid;
    UIDFieldName = uid;
    IMAPLoginFieldName = uid;
    bindDN = "uid=sogo,ou=people,dc=brmartin,dc=co,dc=uk";
    bindPassword = "<from sogo-db-secret>";
    baseDN = "ou=people,dc=brmartin,dc=co,dc=uk";
    canAuthenticate = YES;
    displayName = "Users";
    hostname = "ldap://lldap:3890";
    id = ldap_users;
    isAddressBook = NO;
    filter = "(objectClass=inetOrgPerson)";
  }
);
```

**Note**: `isAddressBook = NO` prevents SoGO from using lldap as a contacts directory (calendar/contacts are out of scope).

---

## Contract 7: Rspamd → Redis (State Storage)

**Protocol**: Redis protocol  
**Transport**: TCP  
**Address**: `mail-redis.default.svc.cluster.local:6379`  
**Direction**: Rspamd reads/writes bayes, greylisting, and rate-limiting data

**Rspamd configuration** (`local.d/redis.conf`):
```
servers = "mail-redis:6379";
```

**Data written by Rspamd**:
- Bayes classifier (learned ham/spam tokens)
- Greylisting state (sender/IP triples)
- Rate limiting counters
- Fuzzy hash cache

**Failure mode**: If Redis is unavailable, Rspamd falls back to in-memory-only operation (no persistent learning). Mail delivery continues.

---

## Contract 8: SoGO → Postfix (SMTP Relay)

**Protocol**: SMTP  
**Transport**: TCP (within cluster)  
**Address**: `postfix.default.svc.cluster.local:587`  
**Direction**: SoGO sends composed/forwarded email through Postfix

**SoGO `sogo.conf`**:
```
SOGoSMTPServer = "smtp://postfix:587";
SOGoSMTPAuthenticationType = PLAIN;
SOGoForceExternalLoginWithEmail = YES;
```

SoGO authenticates outbound submissions to Postfix using the user's LDAP credentials (Postfix delegates SASL to Dovecot which validates against lldap).

---

## Contract 9: SoGO → Dovecot (IMAP Access)

**Protocol**: IMAP  
**Transport**: TCP (within cluster)  
**Address**: `dovecot.default.svc.cluster.local:143`  
**Direction**: SoGO fetches mail from Dovecot via IMAP for display in the webmail UI

**SoGO `sogo.conf`**:
```
SOGoIMAPServer = "imap://dovecot:143";
```

SoGO authenticates to Dovecot using the user's lldap credentials (PLAIN IMAP AUTH over plaintext within the cluster network).

---

## Contract 10: Keycloak → lldap (User Federation)

**Protocol**: LDAP v3  
**Transport**: TCP  
**Address**: `lldap.default.svc.cluster.local:3890`  
**Direction**: Keycloak reads user data from lldap for SSO federation

**Configuration** (set via Keycloak admin UI, not Terraform):

| Setting | Value |
|---------|-------|
| Edit Mode | `READ_ONLY` |
| Connection URL | `ldap://lldap.default.svc.cluster.local:3890` |
| Users DN | `ou=people,dc=brmartin,dc=co,dc=uk` |
| Bind DN | `uid=keycloak,ou=people,dc=brmartin,dc=co,dc=uk` |
| User object classes | `inetOrgPerson` |
| Sync Registrations | `OFF` (lldap rejects writes) |
| Pagination | `OFF` (lldap doesn't support RFC 2696) |

**lldap service account**: A dedicated read-only account (`uid=keycloak`) for Keycloak federation.

---

## External Port Contract

These ports must be reachable from the public internet via Hestia's external IP (192.168.1.5), with router port forwarding configured.

| External Port | Protocol | Routes to | Notes |
|---------------|----------|-----------|-------|
| 25 | TCP/SMTP | Postfix hostPort | Standard inbound relay from other MTAs |
| 465 | TCP/SMTPS | Postfix hostPort | Client submission, implicit TLS |
| 587 | TCP/Submission | Postfix hostPort | Client submission, STARTTLS |
| 143 | TCP/IMAP | Dovecot hostPort | Mail client retrieval, STARTTLS available |
| 993 | TCP/IMAPS | Dovecot hostPort | Mail client retrieval, implicit TLS |
| 110 | TCP/POP3 | Dovecot hostPort | Mail client retrieval, STARTTLS available |
| 995 | TCP/POP3S | Dovecot hostPort | Mail client retrieval, implicit TLS |
| 4190 | TCP/Sieve | Dovecot hostPort | Client-side filter (ManageSieve) |
| 443 | TCP/HTTPS | Traefik → SoGO | Webmail access at `mail.brmartin.co.uk` |
