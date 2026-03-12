# Implementation Plan: Kubernetes Mail Server Migration

**Branch**: `012-k8s-mail-server` | **Date**: 2026-03-11 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/012-k8s-mail-server/spec.md`

## Summary

Migrate the existing mailcow Docker Compose mail server on Hestia to a standalone Kubernetes-native mail stack. The migration replaces mailcow's tightly-coupled components (Postfix, Dovecot, Rspamd, SoGO) with independently managed Kubernetes workloads. Account management is centralised via lldap (Lightweight LDAP) federated into the existing Keycloak SSO. Mailbox data (~30 MB, Maildir format) is migrated via offline rsync during a planned downtime window. IMAP, POP3, and SMTP are exposed directly on Hestia using `hostPort` + `nodeSelector`, matching the existing mailcow port-binding pattern.

## Technical Context

**Language/Version**: HCL (Terraform 1.x) — same as all cluster modules  
**Primary Dependencies**:
- Postfix (MTA): `boky/postfix` — env-var-driven configuration, multi-arch
- Dovecot (IMAP/POP3): `dovecot/dovecot:2.3-latest` — official image, StatefulSet
- Rspamd (spam filter): `rspamd/rspamd:latest` — official image, milter on TCP 11332
- Redis (Rspamd backend): `redis:7-alpine` — Rspamd bayes/greylisting state
- SoGO (webmail): `inverse-inc/sogo` or custom Debian-based image — email-only mode
- lldap (LDAP identity store): `lldap/lldap:stable` — PostgreSQL-backed, multi-arch

**Storage**:
- Dovecot mailboxes: PVC `glusterfs-nfs` StorageClass (`dovecot_mailboxes` volume)
- Dovecot indexes: `emptyDir` (rebuilt on pod restart; avoids mmap issues on NFS)
- Postfix queue: PVC `glusterfs-nfs` StorageClass (`postfix_spool` volume)
- Rspamd data: PVC `glusterfs-nfs` StorageClass (`rspamd_data` volume)
- Redis: `emptyDir` (Rspamd relearns quickly; persistence not required at this scale)
- lldap: External PostgreSQL at `192.168.1.10:5433`, dedicated `lldap` database
- SoGO: External PostgreSQL at `192.168.1.10:5433`, dedicated `sogo` database

**Testing**: Manual verification — mail client connection tests, `doveadm` commands, external mail tester (mail-tester.com), `openssl s_client` for TLS validation  
**Target Platform**: Kubernetes (K3s) — Postfix/Dovecot pinned to Hestia (amd64) via `nodeSelector`; lldap, Rspamd, SoGO may schedule on any node (amd64 or arm64)  
**Project Type**: Infrastructure module (Terraform kubernetes provider)  
**Performance Goals**: Homelab scale — single-digit concurrent connections; standard MTA throughput for personal use  
**Constraints**:
- Mail pods on Hestia must not conflict with mailcow's existing port bindings during parallel operation (pre-cutover)
- Dovecot mailboxes on NFS require `mmap_disable = yes` and `mail_fsync = always`
- Postfix and Dovecot must NOT use Unix sockets for inter-pod communication (TCP only)
- DKIM private keys must be file-mounted (Kubernetes Secret), not stored in Redis

**Scale/Scope**: 2 mail domains (`brmartin.co.uk`, `martinilink.co.uk`), 1 active mailbox (`ben@brmartin.co.uk`), 1 alias, ~30 MB mailbox data

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | ✅ PASS | All resources via Terraform kubernetes provider. No raw YAML manifests. No `ignore_changes`. |
| II. Simplicity First | ✅ PASS | Two modules (`lldap`, `mail`). `mail` groups tightly-coupled components (same pattern as `gitlab` module). No unnecessary abstraction layers. |
| III. High Availability | ⚠️ JUSTIFIED | Mail pods use `nodeSelector: hestia` (single node). Mail servers at homelab scale don't warrant HA — a second SMTP relay would require MX failover DNS changes beyond this scope. Liveness/readiness probes are required on all pods. |
| IV. Storage Patterns | ✅ PASS | PVCs with `glusterfs-nfs` for persistent data. No SQLite on network storage: lldap uses PostgreSQL, SoGO uses PostgreSQL. Dovecot indexes on `emptyDir`. |
| V. Security & Secrets | ✅ PASS | All credentials in Kubernetes Secrets. Per-service PostgreSQL databases and credentials. DKIM keys in Secret, not in Redis. Cilium NetworkPolicies to restrict lldap access to only mail components and Keycloak. |
| VI. Service Mesh & Networking | ✅ PASS | SoGO webmail via Traefik IngressRoute (host-based). Mail TCP ports via `hostPort` on Hestia (Traefik TCP not used — avoids patching Helm-managed Traefik Deployment for a non-HTTP protocol stack). |
| VII. Resource Management | ✅ PASS | `requests` and `limits` required on all containers. Sizes derived from mailcow resource usage (mailcow containers observed to be lightweight). Conservative estimates apply. |
| VIII. Dependency Management | ✅ PASS | Renovate inline comments required on all image references in `modules-k8s/**/*.tf`. |

**Constitution Check Post-Design**: Re-evaluated — no new violations introduced by the Phase 1 design.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| `hostPort` on mail pods (single-node) | Standard mail ports (25, 143, 587, etc.) require real port numbers. Traefik TCP would require patching the Helm-managed Traefik Deployment directly — fragile and not Terraform-managed. NodePort cannot use ports < 30000 without cluster changes. | All alternatives require either cluster-wide changes or non-standard ports that would require client reconfiguration (violating SC-005). |
| Mail stack pinned to Hestia via `nodeSelector` | Port 25 must come from the same IP that has MX DNS + router port forwarding (Hestia: 192.168.1.5). Running Postfix on Heracles or Nyx would require adding new NAT rules. | Accepting downtime on Hestia failure is acceptable for a homelab with one mail user. |

## Project Structure

### Documentation (this feature)

```text
specs/012-k8s-mail-server/
├── plan.md              # This file
├── research.md          # Phase 0 — mailcow discovery + component decisions
├── data-model.md        # Phase 1 — LDAP entities, K8s resource relationships
├── quickstart.md        # Phase 1 — deployment + migration runbook
├── contracts/
│   ├── inter-service.md # Phase 1 — all component-to-component interface specs
│   └── ldap-schema.md   # Phase 1 — lldap LDAP schema contract
└── tasks.md             # Phase 2 — task breakdown (from /speckit.tasks)
```

### Source Code (repository root)

```text
modules-k8s/
├── lldap/
│   ├── main.tf          # Deployment, Service, ConfigMap; PostgreSQL backend
│   └── variables.tf     # hostname, namespace, image_tag, db_*, ldap_base_dn
│
└── mail/
    ├── main.tf          # Postfix StatefulSet, Dovecot StatefulSet,
    │                    # Rspamd Deployment, Redis Deployment, SoGO Deployment,
    │                    # Services, IngressRoute (SoGO), PVCs, ConfigMaps, Secrets
    └── variables.tf     # hostname, namespace, image_tags, lldap_host,
                         # lldap_base_dn, ldap_service_passwords, domains,
                         # db_host, db_port, sogo_db_*, relay_host

kubernetes.tf            # Add: module "k8s_lldap" and module "k8s_mail" calls
```

### Module Boundaries

**`modules-k8s/lldap/`** (standalone, reusable):
- Manages the lldap Deployment and Service only
- Keycloak federation is configured manually via Keycloak admin UI (not Terraform — Keycloak provider not used in this repo)
- lldap admin UI IngressRoute (if exposed) in this module

**`modules-k8s/mail/`** (all mail components):
- Postfix (StatefulSet, `nodeSelector: hestia`, `hostPort` 25/465/587)
- Dovecot (StatefulSet, `nodeSelector: hestia`, `hostPort` 143/993/110/995/4190)
- Rspamd (Deployment, no `nodeSelector` — stateless)
- Redis (Deployment, no `nodeSelector` — stateless)
- SoGO (Deployment, no `nodeSelector` — stateless, served via Traefik)
- All PVCs, ConfigMaps, Secrets, Services, IngressRoute for the above

Grouped in a single module following the `gitlab` module pattern (multiple tightly-coupled components).

---

## Phase 0: Research Summary

All research complete. See `research.md` for full findings.

**Key decisions:**

| Decision | Choice | Rationale |
|----------|--------|-----------|
| MTA | Postfix (`boky/postfix`) | Industry standard; env-var config; multi-arch |
| IMAP/POP3 | Dovecot 2.3 (`dovecot/dovecot:2.3-latest`) | Mailcow already uses Dovecot Maildir; zero format change |
| Spam filter | Rspamd (`rspamd/rspamd:latest`) | Already in use; Postfix milter integration |
| Antivirus | **None** (ClamAV disabled in mailcow, `SKIP_CLAMD=y`) | Not needed; not included |
| Webmail | SoGO (email-only mode) | Specified; `SOGoCalendarModuleEnabled=NO` |
| LDAP store | lldap (`lldap/lldap:stable`, PostgreSQL backend) | Lightweight; Keycloak-federatable; no SQLite |
| Port exposure | `hostPort` + `nodeSelector: hestia` | Matches existing mailcow pattern; no Traefik changes needed |
| Auth integration | lldap primary → Keycloak READ_ONLY federation | lldap does not support Keycloak write-through (by design) |
| Mailbox storage | Dovecot PVC on `glusterfs-nfs` | Constitution IV; `mmap_disable=yes` + `mail_fsync=always` |
| TLS | Wildcard cert from `wildcard-brmartin-tls` (copied to `default` ns) | cert-manager already manages this |
| DKIM keys | Kubernetes Secret (file-mounted) | Redis keys lost on restart; Secrets are durable |

## Phase 1: Design Outputs

All Phase 1 artifacts generated:

- `data-model.md` — lldap LDAP entities, K8s resource relationships, Secret inventory, network topology
- `contracts/inter-service.md` — 10 inter-service contracts (milter, LMTP, SASL, LDAP bind, IMAP, SMTP relay, Redis, external ports)
- `contracts/ldap-schema.md` — lldap LDAP schema, base DN, service accounts, user object definition
- `quickstart.md` — step-by-step deployment + migration + decommission runbook

### Post-Design Constitution Re-Check

No new violations. The design is consistent with all Constitution principles:
- All resources Terraform-managed
- Dovecot indexes on `emptyDir` (avoids NFS mmap issues — Constitution IV)
- Per-service PostgreSQL databases for lldap and SoGO
- DKIM keys in Secrets, not Redis
- `hostPort` deviation documented in Complexity Tracking

**Phase 2** (`/speckit.tasks`) will break this plan into implementable tasks.
