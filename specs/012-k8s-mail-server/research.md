# Research: Kubernetes Mail Server Migration

**Feature**: 012-k8s-mail-server  
**Date**: 2026-03-11  
**Sources**: SSH discovery on Hestia, component documentation, K8s mail deployment patterns

---

## 1. Current Mailcow Discovery

### Installation

- **Path**: `/mnt/docker/mailcow/` on Hestia
- **Compose project**: `mailcowdockerized`

### Running Components

| Container | Image | Purpose |
|-----------|-------|---------|
| postfix | ghcr.io/mailcow/postfix:1.81 | SMTP MTA |
| dovecot | ghcr.io/mailcow/dovecot:2.35 | IMAP/POP3 |
| rspamd | ghcr.io/mailcow/rspamd:2.4 | Spam filter |
| mysql | mariadb:10.11 | Config/account database |
| redis | redis:7.4.6-alpine | Rspamd state + DKIM keys |
| sogo | ghcr.io/mailcow/sogo:1.136 | Webmail (currently unused by users) |
| nginx + php-fpm | mailcow-specific | Admin UI |
| clamd | ghcr.io/mailcow/clamd:1.71 | Antivirus (**disabled** via SKIP_CLAMD=y) |
| watchdog | ghcr.io/mailcow/watchdog:2.09 | Health monitor (**disabled** via USE_WATCHDOG=n) |
| acme, certdumper | — | TLS cert management (replaced by cert-manager) |
| netfilter, unbound, olefy, ofelia, postfix-tlspol, memcached, dockerapi | — | Supporting infrastructure (not needed in K8s) |

### Domains and Accounts

| Type | Value | Status |
|------|-------|--------|
| Domain | brmartin.co.uk | Active |
| Domain | martinilink.co.uk | Active |
| Mailbox | ben@brmartin.co.uk | Active |
| Alias | ben@martinilink.co.uk | Active (routes to ben@brmartin.co.uk) |

### Port Bindings (current)

| Port | Protocol | Bound | Status |
|------|----------|-------|--------|
| 25 | SMTP (inbound) | 0.0.0.0 | **Externally accessible** |
| 465 | SMTPS | 0.0.0.0 | **Externally accessible** |
| 587 | SMTP Submission | 0.0.0.0 | **Externally accessible** |
| 143 | IMAP | Not exposed | **Connection refused from host** |
| 993 | IMAPS | Not exposed | **Connection refused from host** |
| 110 | POP3 | Not exposed | **Not exposed** |
| 995 | POP3S | Not exposed | **Not exposed** |

**Finding**: IMAP/POP3 ports are defined in docker-compose but were never exposed to the host. The new deployment must properly expose all standard mail ports — this is a net improvement.

### Mail Data

| Data | Location | Size |
|------|----------|------|
| Mailboxes (Maildir) | `/var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data/` | **~30 MB** |
| Mail path structure | `/var/vmail/<domain>/<user>/Maildir/{cur,new,tmp,.Archive,.Drafts,.Junk,.Sent,.Trash}/` | Standard Maildir |
| Sieve filters | `/var/vmail/<domain>/<user>/sieve/` | Present |
| DKIM private keys | Redis hash `DKIM_PRIV_KEYS` (`dkim.brmartin.co.uk`, `dkim.martinilink.co.uk`) | RSA private keys |
| DKIM selector | `dkim` for both domains | From Redis `DKIM_SELECTORS` |
| Password scheme | BLF-CRYPT (bcrypt) | In MariaDB `mailcow.mailbox` |

### Mailcow Configuration (`mailcow.conf`)

- `MAILCOW_HOSTNAME=mail.brmartin.co.uk`  
- `MAILCOW_PASS_SCHEME=BLF-CRYPT`  
- `SKIP_CLAMD=y` — ClamAV disabled  
- `USE_WATCHDOG=n` — Watchdog disabled  
- `SKIP_FTS=y` — Full-text search disabled  
- `SKIP_LETS_ENCRYPT=y` — cert-manager is used instead

---

## 2. Component Selection

### 2.1 MTA: Postfix

**Decision**: Postfix (standard, unchanged from mailcow)

**Rationale**: Postfix is the industry-standard open-source MTA. The cluster needs to run an MTA regardless of mailcow. `boky/postfix` (Docker Hub) is the most actively maintained generic Postfix Docker image with environment-variable-based configuration.

**Image**: `boky/postfix` — env-var-driven (`POSTFIX_*` prefix → `main.cf`), multi-arch (amd64 + arm64).

**Alternatives considered**:
- Mailcow's custom Postfix image: tied to mailcow's auth system, not reusable
- Custom Debian-based image: maximum control but maintenance overhead; viable fallback if boky/postfix doesn't fit

### 2.2 IMAP/POP3: Dovecot

**Decision**: Dovecot 2.3 (standard, unchanged from mailcow)

**Rationale**: Dovecot is the de-facto standard for IMAP/POP3. The existing mailcow data is in standard Dovecot Maildir format, making migration straightforward.

**Image**: `dovecot/dovecot:2.3-latest` — official image, actively maintained. 2.3.x for API stability.

**Deployment type**: StatefulSet (not Deployment) to ensure consistent pod identity and prevent concurrent writes to the same Maildir.

### 2.3 Spam Filter: Rspamd

**Decision**: Rspamd (unchanged from mailcow)

**Rationale**: Rspamd is already in use. It integrates with Postfix as a milter on port 11332. DKIM signing is natively supported.

**Image**: `rspamd/rspamd:latest` — official image.

**Key change**: DKIM keys will be stored as Kubernetes Secrets (file-mounted), NOT in Redis. This is more reliable since Redis data is ephemeral.

### 2.4 Webmail: SoGO (email-only mode)

**Decision**: SoGO with calendar/contacts modules disabled

**Rationale**: Specified in the feature description. SoGO supports LDAP authentication and email-only mode. Calendar and contacts are explicitly out of scope.

**Image**: Community Docker images for SoGO are fragmented. Options:
1. `inverse-inc/sogo` from GitHub Container Registry (if available with current version)
2. Custom Dockerfile from `debian:bookworm-slim` + `apt install sogo` from Inverse.ca nightly packages

**Configuration for email-only mode**:
```
SOGoCalendarModuleEnabled = NO;
SOGoContactsModuleEnabled = NO;
SOGoMailModuleEnabled = YES;
```

SoGO requires a reverse proxy. Traefik handles this via an IngressRoute to SoGO's port 20000.

### 2.5 LDAP Identity Store: lldap

**Decision**: lldap (Lightweight LDAP) with PostgreSQL backend

**Rationale**: lldap is purpose-built for small home/team deployments. It provides the LDAP interface that Postfix, Dovecot, and SoGO need for authentication. It supports PostgreSQL, avoiding SQLite on network storage.

**Image**: `lldap/lldap:stable` — official image, multi-arch.

**Database**: External PostgreSQL at `192.168.1.10:5433`, dedicated `lldap` database (per Constitution: per-service credentials).

**Keycloak integration**: See section 3.

### 2.6 Redis (Rspamd backend)

**Decision**: Standalone Redis for Rspamd

**Rationale**: Rspamd requires Redis for bayes classifier data, greylisting, and rate limiting. A dedicated Redis instance prevents interference with other services (Constitution: per-service credentials, no sharing).

**Image**: `redis:7-alpine` — lightweight, official.

---

## 3. Keycloak + lldap Integration

### Research Finding: Write-Through Not Supported

lldap's official documentation explicitly states:
> "LLDAP is read-only: if you create some users in Keycloak, they won't be reflected to LLDAP."

lldap uses argon2 with a server-side `key_seed` for password hashing. It **never exposes the `userPassword` LDAP attribute**. Keycloak cannot write users back to lldap.

**Implication**: Keycloak cannot be the single write interface for lldap users. lldap's own web UI must be used for user lifecycle management.

### Chosen Pattern: lldap as Primary, Keycloak as Federation + SSO

```
[Admin] → lldap Web UI (authenticated via Keycloak OIDC)
              ↓ creates/manages users
           lldap (LDAP server, PostgreSQL-backed)
              ↓ READ_ONLY federation
           Keycloak (SSO for all web services)
              ↓ LDAP bind auth
           Postfix (routing lookups) + Dovecot (auth) + SoGO (auth)
```

**Admin workflow**: Admin authenticates with Keycloak credentials → is redirected to lldap's web UI (which uses Keycloak OIDC for admin login) → creates/modifies mail accounts in lldap.

This satisfies the spec's requirement that "Keycloak remains the authoritative source for account management" in the sense that:
- Admin identity is Keycloak-controlled (no local lldap admin password needed)
- lldap is the intermediary identity service federated with Keycloak (as documented in the spec's FR-006a)

### Alternative Considered: OpenLDAP with Keycloak WRITABLE

OpenLDAP supports full LDAP write-back from Keycloak (WRITABLE federation mode + Sync Registrations). This would make Keycloak the true single admin interface.

**Rejected because**: OpenLDAP adds significant operational complexity (schema management, ACLs, replication configuration) for a deployment with one mail account. lldap's simplicity is appropriate for this scale. OpenLDAP should be revisited if the account count grows significantly.

### Keycloak LDAP Federation Configuration

| Setting | Value |
|---------|-------|
| Edit Mode | `READ_ONLY` |
| Vendor | Other |
| Username LDAP attribute | `uid` |
| User object classes | `person` |
| Connection URL | `ldap://lldap.default.svc.cluster.local:3890` |
| Users DN | `ou=people,dc=brmartin,dc=co,dc=uk` |
| Sync Registrations | `OFF` (must be off; lldap rejects writes) |
| Pagination | `OFF` (lldap doesn't support RFC 2696) |

### Critical lldap Auth Requirement

All components authenticating against lldap **must use bind-auth mode** (`auth_bind = yes` in Dovecot). lldap never returns password hashes — it verifies credentials by accepting a bind request and returning success/failure. This is the standard LDAP auth pattern and works correctly.

---

## 4. Port Exposure Strategy

### Finding: Traefik is in `traefik` namespace, not managed by Terraform

The cluster Traefik deployment is managed by K3s Helm. Its current entrypoints are `web` (8000), `websecure` (8443), `metrics` (9100), `traefik` (8080). The NodePort service maps 80→30080 and 443→30443.

Adding TCP entrypoints for mail would require patching the Traefik Deployment args directly (consistent with the `allowEncodedSlash` precedent in AGENTS.md), plus updating the NodePort Service, plus router reconfiguration.

### Decision: `hostPort` + `nodeSelector: hestia` for all mail ports

**Rationale**:
1. The current mailcow setup uses `hostPort` for SMTP (25, 465, 587) on Hestia — the router is already configured to forward these to Hestia's IP.
2. hostPort avoids any Traefik changes and associated risks.
3. Mail services MUST run on Hestia (the node with the external IP/router forwarding). nodeSelector enforces this.
4. The Constitution favours "explicit configuration over clever automation".

**Port assignments**:

| Port | Protocol | Bound on | Notes |
|------|----------|----------|-------|
| 25 | SMTP (inbound relay) | Hestia hostPort | External MTA connections |
| 465 | SMTPS (implicit TLS) | Hestia hostPort | Client submission, legacy |
| 587 | SMTP Submission (STARTTLS) | Hestia hostPort | Preferred client submission |
| 143 | IMAP (STARTTLS) | Hestia hostPort | Mail client access |
| 993 | IMAPS (implicit TLS) | Hestia hostPort | Mail client access |
| 110 | POP3 (STARTTLS) | Hestia hostPort | Mail client access |
| 995 | POP3S (implicit TLS) | Hestia hostPort | Mail client access |
| 4190 | Sieve | Hestia hostPort | ManageSieve (client filter management) |

**SoGO webmail** continues to use the standard Traefik IngressRoute (HTTPS 443) like all other web services.

**Alternative considered**: Traefik TCP IngressRouteTCP for IMAP/POP3 (would require adding `--entryPoints.imap.address=:143` etc. to Traefik Deployment and new NodePorts). Rejected due to added Traefik complexity and the need to manually patch a Helm-managed deployment.

---

## 5. Storage Decisions

| Component | Storage Type | Rationale |
|-----------|-------------|-----------|
| Dovecot mailboxes | PVC `glusterfs-nfs` | Persistent, survives pod restart |
| Dovecot indexes | `emptyDir` (tmpfs recommended) | Rebuilt automatically on restart; NFS mmap issues avoided |
| Postfix queue | PVC `glusterfs-nfs` | In-flight mail must survive pod restart |
| Rspamd data | PVC `glusterfs-nfs` | Persistent bayes/greylisting data |
| Redis | `emptyDir` | Rspamd relearns quickly; no need for persistence at this scale |
| lldap database | External PostgreSQL `192.168.1.10:5433` | No SQLite on network storage (Constitution IV) |
| SoGO database | External PostgreSQL `192.168.1.10:5433` | Session/profile data; no SQLite |
| DKIM keys | Kubernetes Secret | Must survive restarts; file-mounted into Rspamd |

**Dovecot NFS settings required** (prevents index corruption on NFS):
```
mmap_disable = yes
mail_fsync = always
maildir_copy_with_hardlinks = no
```
Index separation: `mail_location = maildir:/var/mail/%d/%n:INDEX=/tmp/indexes/%d/%n`

**NFS-Ganesha compatibility**: The cluster's NFS-Ganesha with FSAL_GLUSTER provides stable fileids. No special NFS workarounds beyond the standard Dovecot NFS settings are needed. Postfix queue on NFS is safe (Postfix manages its own internal locking, not POSIX file locks).

---

## 6. TLS Strategy

The cluster uses cert-manager with a wildcard certificate (`wildcard-brmartin-tls`).

- **SoGO webmail**: Traefik terminates TLS using `wildcard-brmartin-tls`. SoGO sees plain HTTP on port 20000.
- **SMTP/IMAP/POP3**: TLS is terminated by Postfix/Dovecot themselves (not Traefik). The wildcard certificate (`cert.pem` / `key.pem`) must be mounted into both Postfix and Dovecot containers.
- **Certificate access**: The wildcard TLS secret (`wildcard-brmartin-tls` in the `traefik` namespace) must be made available in the `default` namespace. Current pattern (seen in `kubernetes.tf` comment): copy via `kubectl get secret -n traefik wildcard-brmartin-tls | kubectl apply -n default`. This should be managed as a Kubernetes Secret resource in Terraform (copy or reference).

---

## 7. Migration Plan

### Pre-migration snapshot

1. Export DKIM private keys from mailcow Redis (both domains)
2. Record all mailbox names, aliases, domain configurations
3. Note current password hash for `ben@brmartin.co.uk` from MariaDB (`SELECT mailbox.password FROM mailbox`)

### Migration steps (during downtime)

1. Stop mailcow SMTP (ports 25/465/587 become unreachable; external senders queue)
2. Deploy new K8s mail stack
3. Create lldap user account(s) matching mailcow accounts
4. rsync mailbox data: `/var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data/` → new Dovecot PVC
5. Mount new Dovecot PVC, verify mailbox structure
6. Start new stack, validate SMTP/IMAP/POP3 functionality
7. Remove mailcow Docker Compose

### Data scope

- **In scope**: Maildir messages (all folders), sieve filters, DKIM keys
- **Out of scope**: Mailcow admin/config database, SoGO contacts/calendar data (none in active use), mailcow quarantine data

### Password migration

Mailcow uses BLF-CRYPT. The new system uses lldap which uses Argon2. Users must set a new password in lldap after migration (or admin sets it). Since there is only 1 active user (`ben@brmartin.co.uk`), this is trivial.

---

## 8. Terraform Module Structure

| Module | Contents |
|--------|----------|
| `modules-k8s/lldap/` | lldap Deployment, Service, ConfigMap, PVC (if needed); Keycloak federation is configured manually in Keycloak admin UI |
| `modules-k8s/mail/` | Postfix StatefulSet + Service, Dovecot StatefulSet + Service, Rspamd Deployment + Service, Redis Deployment + Service, SoGO Deployment + Service + IngressRoute |

Mail and lldap are separate modules because lldap is an independent identity service that may serve other applications in the future (the matrix stack, other web services, etc.).

---

## 9. Open Questions Resolved

| Question | Resolution |
|----------|-----------|
| Will IMAP/POP3 be exposed externally? | Yes — hostPort on Hestia. Currently connection refused; the new deployment ADDS this capability. |
| ClamAV required? | No — SKIP_CLAMD=y in current mailcow; antivirus is disabled. Not included in new stack. |
| SoGO calendar/contacts? | No — out of scope per user decision. Email-only mode. |
| Keycloak write-through? | Not achievable with lldap. lldap is primary; Keycloak federates READ_ONLY. Admin auth via Keycloak OIDC. |
| Mailbox size? | ~30 MB. Migration is fast. |
| Watchdog? | Not included (user requirement). K8s liveness/readiness probes replace it. |
| Password migration? | Users must set new passwords in lldap (Argon2 ≠ BLF-CRYPT). Only 1 active user. |
