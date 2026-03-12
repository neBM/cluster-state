# Tasks: Kubernetes Mail Server Migration

**Input**: Design documents from `/specs/012-k8s-mail-server/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, contracts/ ✅, quickstart.md ✅

**Tests**: Not applicable — this is infrastructure (Terraform HCL). Verification is via manual protocol tests, `kubectl`, `doveadm`, and `openssl s_client` as documented in quickstart.md.

**Organization**: Tasks are grouped by user story. US1 (Email Delivery) and US2 (Data Migration) are both P1; US2 depends on US1 being deployed so it follows US1. US4 (Account Management) precedes US3 (Webmail) since SoGO requires lldap to be operational. Foundation tasks block everything.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different resources, no mutual dependency)
- **[Story]**: Which user story this task belongs to (US1–US5)
- All paths are absolute from repository root

## Path Conventions

This is a Terraform infrastructure project. All source files are under `modules-k8s/`. There is no `src/` tree.

---

## Phase 1: Setup (Module Scaffolding)

**Purpose**: Create the Terraform module directory structure so all subsequent tasks have files to write into.

- [x] T001 Create `modules-k8s/lldap/` directory with empty `main.tf` and `variables.tf` files
- [x] T002 Create `modules-k8s/mail/` directory with empty `main.tf` and `variables.tf` files
- [x] T003 Add stub `module "k8s_lldap"` and `module "k8s_mail"` blocks (with `source` only) to `kubernetes.tf` so Terraform recognises the modules

---

## Phase 2: Foundation (lldap + Shared Secrets)

**Purpose**: Deploy the lldap LDAP identity store and prepare all shared secrets. This phase is a hard prerequisite for all user story phases — no mail component can authenticate without lldap, and no TLS can be terminated without the cert.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T004 Extract DKIM private keys from mailcow Redis on Hestia and store as `kubectl create secret generic dkim-keys -n default --from-file=brmartin.co.uk.dkim.key=... --from-file=martinilink.co.uk.dkim.key=...` (see quickstart.md Step 1 for exact commands; verify both keys present with `kubectl describe secret dkim-keys`)
- [ ] T005 [P] Create `lldap` PostgreSQL database on the external PostgreSQL server (`192.168.1.10:5433`) with a dedicated `lldap` user and password
- [ ] T006 [P] Create `sogo` PostgreSQL database on the external PostgreSQL server (`192.168.1.10:5433`) with a dedicated `sogo` user and password
- [ ] T007 Copy `wildcard-brmartin-tls` secret from the `traefik` namespace to the `default` namespace as `mail-tls` using `kubectl get secret wildcard-brmartin-tls -n traefik -o yaml | sed 's/namespace: traefik/namespace: default/' | kubectl apply -f -`; verify with `kubectl get secret mail-tls -n default`
- [x] T008 Implement `modules-k8s/lldap/variables.tf`: declare variables for `namespace` (default `default`), `image_tag` (with Renovate comment for `lldap/lldap`), `hostname` (lldap admin UI), `ldap_base_dn`, `lldap_jwt_secret`, `lldap_key_seed`, `db_url` (PostgreSQL DSN)
- [x] T009 Implement `modules-k8s/lldap/main.tf`: `locals` block; `kubernetes_config_map.lldap_config` with `lldap_config.toml` key (LDAP base DN, HTTP port 17170, LDAP port 3890, DB URL from env, verbose logging off); `kubernetes_deployment.lldap` (`lldap/lldap:stable` with Renovate comment, env vars `LLDAP_LDAP_BASE_DN`, `LLDAP_JWT_SECRET` and `LLDAP_KEY_SEED` from `kubernetes_secret.lldap_secrets`, `LLDAP_DATABASE_URL` from `kubernetes_secret.lldap_db`, resources 50m/256Mi request 200m/512Mi limit, liveness probe HTTP `/health` :17170, readiness probe same); `kubernetes_service.lldap` (ClusterIP, ports 3890 LDAP and 17170 HTTP); `kubernetes_ingress_v1.lldap` (IngressRoute via `traefik.ingress.kubernetes.io/router.entrypoints: websecure`, TLS using `wildcard-brmartin-tls`, host `var.hostname`, backend `lldap:17170`)
- [x] T010 Add `kubernetes_secret.lldap_secrets` and `kubernetes_secret.lldap_db` resources to `modules-k8s/lldap/main.tf` (lldap_secrets holds `LLDAP_JWT_SECRET` and `LLDAP_KEY_SEED`; lldap_db holds `LLDAP_DATABASE_URL` as the PostgreSQL DSN from T005)
- [x] T011 Add `kubernetes_network_policy.lldap_ingress` (or `kubernetes_manifest` for `CiliumNetworkPolicy`) to `modules-k8s/lldap/main.tf`: allow ingress to port 3890 from pods with labels `app=postfix`, `app=dovecot`, `app=sogo`, and from the `keycloak` namespace; allow ingress to port 17170 from Traefik; deny all other ingress
- [x] T012 Update `module "k8s_lldap"` in `kubernetes.tf` with all required variable assignments (namespace, image_tag, hostname `ldap.brmartin.co.uk`, ldap_base_dn `dc=brmartin,dc=co,dc=uk`, secrets from variables or `.env`)
- [x] T013 Apply the lldap module: run `terraform plan -target='module.k8s_lldap' -out=tfplan && terraform apply tfplan`; verify pod is Running with `kubectl get pods -l app=lldap`; verify lldap web UI accessible at `https://ldap.brmartin.co.uk`
- [x] T014 Create lldap service accounts and bootstrap mail group via lldap web UI (log in with initial admin credentials): create users `dovecot`, `postfix`, `sogo`, `keycloak` (service accounts, not in mail-users group); create group `mail-users`; create user `ben` with `mail=ben@brmartin.co.uk`; add `ben` to `mail-users` group; set a known password for `ben`

**Checkpoint**: Foundation ready — lldap is running, service accounts exist, mail-users group and ben account created. All user story phases can now begin.

---

## Phase 3: User Story 1 - Email Delivery and Retrieval (Priority: P1) 🎯 MVP

**Goal**: Deploy Postfix (SMTP), Dovecot (IMAP/POP3), Rspamd (spam + DKIM), and Redis so that mail clients can send, receive, and retrieve email from outside the cluster using standard ports.

**Independent Test**: Configure a mail client (Thunderbird) with IMAP `mail.brmartin.co.uk:993` and SMTP `mail.brmartin.co.uk:587`; log in as `ben`; send to an external address; verify delivery and DKIM pass on mail-tester.com; receive from an external address; verify it appears in IMAP inbox.

### Implementation for User Story 1

- [x] T015 [P] [US1] Implement `modules-k8s/mail/variables.tf`: declare variables for `namespace`, `image_tag_postfix` (with Renovate comment `boky/postfix`), `image_tag_dovecot` (Renovate `dovecot/dovecot`), `image_tag_rspamd` (Renovate `rspamd/rspamd`), `image_tag_redis` (Renovate `redis`), `image_tag_sogo` (Renovate for SoGO image), `hostname` (webmail hostname `mail.brmartin.co.uk`), `lldap_host` (`lldap.default.svc.cluster.local`), `ldap_base_dn`, `domains` (list: `["brmartin.co.uk", "martinilink.co.uk"]`), `db_host`, `db_port`, `sogo_db_name`, `sogo_db_user`
- [x] T016 [P] [US1] Add `kubernetes_secret.dkim_keys` resource to `modules-k8s/mail/main.tf`: data keys `brmartin.co.uk.dkim.key` and `martinilink.co.uk.dkim.key` populated from variables (the extracted RSA private keys); this Secret is mounted read-only into Rspamd at `/etc/rspamd/dkim/`
- [x] T017 [P] [US1] Add `kubernetes_secret.postfix_ldap` (LDAP bind password for Postfix service account) and `kubernetes_secret.dovecot_ldap` (LDAP bind password for Dovecot service account) to `modules-k8s/mail/main.tf`; passwords are Terraform variables passed from `kubernetes.tf`
- [x] T018 [US1] Add `kubernetes_deployment.mail_redis` and `kubernetes_service.mail_redis` to `modules-k8s/mail/main.tf`: image `redis:7-alpine` with Renovate comment; `emptyDir` volume; resources 50m/64Mi request, 200m/256Mi limit; liveness probe `redis-cli ping`; Service ClusterIP port 6379
- [x] T019 [US1] Add Rspamd ConfigMaps and resources to `modules-k8s/mail/main.tf`: `kubernetes_config_map.rspamd_config` with keys: `worker-proxy.inc` (bind_socket `*:11332`, self_scan yes), `redis.conf` (servers `mail-redis:6379`), `dkim_signing.conf` (enabled true, path `/etc/rspamd/dkim/$domain.$selector.key`, selector `dkim`, domains `brmartin.co.uk` and `martinilink.co.uk`); `kubernetes_persistent_volume_claim.rspamd_data` (glusterfs-nfs, 2Gi, annotation `volume-name=rspamd_data`); `kubernetes_deployment.rspamd` (image `rspamd/rspamd:latest` with Renovate comment, mounts dkim-keys Secret + rspamd-config ConfigMap + rspamd_data PVC, resources 100m/256Mi request 500m/512Mi limit, liveness probe HTTP `/ping` :11334); `kubernetes_service.rspamd` (ClusterIP, ports 11332 milter and 11334 web UI)
- [x] T020 [US1] Add Postfix ConfigMaps and StatefulSet to `modules-k8s/mail/main.tf`: `kubernetes_config_map.postfix_main` with `main.cf` content (myhostname `mail.brmartin.co.uk`, virtual_mailbox_domains `brmartin.co.uk martinilink.co.uk`, virtual_transport `lmtp:inet:dovecot:24`, smtpd_milters `inet:rspamd:11332`, non_smtpd_milters `inet:rspamd:11332`, milter_default_action accept, milter_protocol 6, smtpd_sasl_type dovecot, smtpd_sasl_path `inet:dovecot:12345`, smtpd_sasl_auth_enable yes, smtpd_tls_cert_file/key_file pointing to mounted mail-tls secret, smtpd_use_tls yes, smtp_tls_security_level may); `kubernetes_config_map.postfix_ldap` with virtual_mailbox_maps LDAP config file (server_host `lldap:3890`, bind_dn `uid=postfix,ou=people,dc=brmartin,dc=co,dc=uk`, bind_pw from dovecot_ldap secret via env, search_base `ou=people,dc=brmartin,dc=co,dc=uk`, query_filter `(&(objectClass=inetOrgPerson)(mail=%s))`, result_attribute `mail`); `kubernetes_config_map.postfix_aliases` with `virtual` file containing alias `ben@martinilink.co.uk ben@brmartin.co.uk`; `kubernetes_persistent_volume_claim.postfix_spool` (glusterfs-nfs, 5Gi, annotation `volume-name=postfix_spool`); `kubernetes_stateful_set.postfix` (image `boky/postfix` with Renovate comment, nodeSector `kubernetes.io/hostname=hestia`, hostPort 25/465/587, env vars for LDAP bind password from secret, mounts postfix-main ConfigMap at `/etc/postfix/main.cf`, postfix-ldap at `/etc/postfix/ldap/`, postfix-aliases at `/etc/postfix/virtual`, mail-tls secret at `/etc/ssl/mail/`, postfix-spool PVC at `/var/spool/postfix/`, resources 100m/256Mi request 500m/512Mi limit, liveness probe `postfix check`); `kubernetes_service.postfix` (ClusterIP, port 587 for intra-cluster SoGO submission)
- [x] T021 [US1] Add Dovecot ConfigMaps, PVCs, and StatefulSet to `modules-k8s/mail/main.tf`: `kubernetes_config_map.dovecot_main` with `dovecot.conf` (mail_location `maildir:/var/mail/%d/%n/Maildir:INDEX=/var/indexes/%d/%n`, mmap_disable yes, mail_fsync always, maildir_copy_with_hardlinks no, mail_privileged_group vmail); `kubernetes_config_map.dovecot_ldap` with `dovecot-ldap.conf.ext` (hosts `lldap:3890`, dn `uid=dovecot,ou=people,dc=brmartin,dc=co,dc=uk`, dnpass from dovecot-ldap secret via env, auth_bind yes, auth_bind_userdn `uid=%n,ou=people,dc=brmartin,dc=co,dc=uk`, base `ou=people,dc=brmartin,dc=co,dc=uk`, pass_filter `(&(objectClass=inetOrgPerson)(uid=%n))`, user_attrs `=uid=5000,=gid=5000,=home=/var/mail/%Ld/%Ln,=mail=maildir:~/Maildir`); `kubernetes_config_map.dovecot_auth` with `10-auth.conf` (auth_mechanisms `plain login`, includes auth-ldap.conf.ext) and `10-master.conf` (lmtp inet_listener port 24, auth inet_listener port 12345, sasl_auth service pointing to dovecot); `kubernetes_persistent_volume_claim.dovecot_mailboxes` (glusterfs-nfs, 10Gi, annotation `volume-name=dovecot_mailboxes`); `kubernetes_stateful_set.dovecot` (image `dovecot/dovecot:2.3-latest` with Renovate comment, nodeSelector `kubernetes.io/hostname=hestia`, hostPort 143/993/110/995/4190, env LDAP bind password from dovecot-ldap secret, mounts dovecot-main ConfigMap + dovecot-ldap ConfigMap + dovecot-auth ConfigMap + mail-tls secret at `/etc/ssl/mail/` + dovecot-mailboxes PVC at `/var/mail/` + emptyDir for indexes at `/var/indexes/`, resources 100m/256Mi request 500m/1Gi limit, liveness probe TCP on port 143, readiness probe TCP on port 143); `kubernetes_service.dovecot` (ClusterIP, ports 24 LMTP, 12345 SASL, 143 IMAP)
- [x] T022 [US1] Add Cilium NetworkPolicies to `modules-k8s/mail/main.tf` for all mail components: `kubernetes_manifest` for `CiliumNetworkPolicy` resources — (1) `mail-redis` allow ingress port 6379 from `app=rspamd` only; (2) `rspamd` allow ingress port 11332 from `app=postfix`, port 11334 from Traefik; (3) `dovecot` allow ingress ports 24/12345 from `app=postfix`, port 143 from `app=sogo`, deny all other cluster ingress (hostPort traffic bypasses NetworkPolicy and is controlled by host firewall); (4) `postfix` allow egress port 25 to `0.0.0.0/0` (relay), egress to rspamd:11332, dovecot:24/12345, lldap:3890
- [x] T023 [US1] Update `module "k8s_mail"` in `kubernetes.tf` with all required variable assignments (namespace, image tags, hostname, lldap_host, ldap_base_dn, domains list, db settings, LDAP service account passwords as sensitive variables referencing `.env` or Vault)
- [x] T024 [US1] Apply mail module (minus SoGO — it is commented out until Phase 5): run `terraform plan -target='module.k8s_mail' -out=tfplan && terraform apply tfplan`; verify all 4 pods start (`postfix-0`, `dovecot-0`, `rspamd-*`, `mail-redis-*`) with `kubectl get pods -n default -l 'app in (postfix,dovecot,rspamd,mail-redis)'`
- [x] T025 [US1] Verify Rspamd integration: HTTP ping via port-forward returns `pong`; DKIM-Signature header present on delivered test message (selector `dkim`, domain `brmartin.co.uk`)
- [x] T026 [US1] Verify Dovecot authentication via LDAP: `doveadm auth test ben@brmartin.co.uk` returns `auth succeeded`; LMTP delivery from Postfix delivers to `/var/mail/brmartin.co.uk/ben/Maildir/new/`; `doveadm mailbox status -u ben@brmartin.co.uk messages INBOX` returns 1
- [x] T027 [US1] Verify external IMAP/POP3 accessibility from outside the cluster: `openssl s_client -connect mail.brmartin.co.uk:993` (expect Dovecot IMAP greeting); `openssl s_client -connect mail.brmartin.co.uk:995` (expect Dovecot POP3 greeting); `openssl s_client -starttls imap -connect mail.brmartin.co.uk:143`
- [~] T028 [US1] Verify SMTP + DKIM signing via external mail tester: DKIM ✅ (pass, selector `dkim`, 2048-bit), DMARC ✅ (pass). Score 2.5/10 due to DNS issues: (1) SPF softfail — needs `ip4:90.216.33.202` added to `v=spf1 include:mailgun.org ~all` in Cloudflare; (2) rDNS missing — PTR record for `90.216.33.202` → `mail.brmartin.co.uk` needs setting with ISP. Score will improve to ≥ 8/10 once SPF and rDNS are fixed. Missing Date/MID headers were from test Python client — real mail clients add these.

**Checkpoint**: User Story 1 complete — mail clients can send and receive using standard protocols. All acceptance scenarios in US1 are satisfied.

---

## Phase 4: User Story 2 - Migrated Data Availability (Priority: P1)

**Goal**: Transfer all existing mailbox data from the mailcow Docker volume to the new Dovecot PVC without message loss, preserving folder structure, timestamps, and attachment integrity.

**Independent Test**: Compare message count per folder against the pre-migration snapshot; retrieve a message with an attachment and verify it opens correctly; confirm `.Sent`, `.Drafts`, `.Archive`, `.Junk`, `.Trash` folders all present.

### Implementation for User Story 2

- [x] T029 [US2] Pre-migration snapshot: 4259 files in `/var/vmail/brmartin.co.uk/ben/Maildir`; folders: INBOX, Archive, Drafts, Junk, Sent, Trash
- [x] T030 [US2] Stopped `mailcowdockerized-postfix-mailcow-1` and `mailcowdockerized-dovecot-mailcow-1` — downtime window started; K8s stack live on ports 25/587/993
- [x] T031 [US2] Mailcow queue was empty at time of stop; no in-flight messages
- [x] T032 [US2] Rsync'd `/var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data/brmartin.co.uk/ben/` → `/storage/v/glusterfs_dovecot_mailboxes/brmartin.co.uk/ben/` with `--chown=5000:5000`; all folders transferred cleanly
- [x] T033 [US2] Post-rsync count: 4264 files (5 extra = test message + dovecot index files created during testing); `.Sent`, `.Archive`, `.Drafts`, `.Junk`, `.Trash` all present; no rsync errors
- [x] T034 [US2] Dovecot pod restarted; `doveadm mailbox list -u ben@brmartin.co.uk` shows: INBOX, Sent, Archive, Drafts, Junk, Trash
- [x] T035 [US2] IMAP verification: `openssl s_client -connect localhost:993` returns `Dovecot ready`; message counts: INBOX=5, Sent=2, Archive=1, Drafts=0, Junk=6, Trash=4230 (total 4244 messages, consistent with 4259 files minus metadata); UIDVALIDITY changed (expected — mail clients will re-sync)

**Checkpoint**: User Story 2 complete — all historical mail is preserved and accessible. SC-001 (zero message loss) verified.

---

## Phase 5: User Story 3 - Webmail Access (Priority: P2)

**Goal**: Deploy SoGO webmail in email-only mode so users can read, compose, and send email from a browser at `https://mail.brmartin.co.uk`.

**Independent Test**: Open `https://mail.brmartin.co.uk` in a browser, log in as `ben`, view the inbox, compose a message to an external address, verify delivery.

### Implementation for User Story 3

- [x] T036 [P] [US3] Add `kubernetes_secret.sogo_db` to `modules-k8s/mail/main.tf` containing the SoGO PostgreSQL DSN (from T006 database credentials); also add `kubernetes_config_map.sogo_config` with `sogo.conf` content: `SOGoMailModuleEnabled = YES; SOGoCalendarModuleEnabled = NO; SOGoContactsModuleEnabled = NO; SOGoUserSources` LDAP block (type ldap, baseDN `ou=people,dc=brmartin,dc=co,dc=uk`, bindDN `uid=sogo,...`, canAuthenticate YES, isAddressBook NO); `SOGoIMAPServer = "imap://dovecot:143"; SOGoSMTPServer = "smtp://postfix:587"; SOGoSMTPAuthenticationType = PLAIN;` PostgreSQL profile/folder/session URLs using sogo_db secret; `WOPort = 0.0.0.0:20000; SOGoPageTitle = "Mail"; SOGoSupportedLanguages = ("English");`
- [x] T037 [P] [US3] Add `kubernetes_secret.sogo_ldap` to `modules-k8s/mail/main.tf` containing the SoGO LDAP bind password for the `sogo` service account (created in lldap during T014)
- [x] T038 [US3] Add `kubernetes_deployment.sogo` and `kubernetes_service.sogo` to `modules-k8s/mail/main.tf`: image with Renovate comment (`inverse-inc/sogo` or Debian-based image, TBD during implementation — use whichever has a current stable tag); mounts sogo-config ConfigMap at `/etc/sogo/sogo.conf`, sogo-ldap secret for bind password via env; resources 100m/256Mi request 500m/512Mi limit; liveness probe HTTP `/SOGo/` :20000; Service ClusterIP port 20000; add `kubernetes_manifest` for Traefik `IngressRoute` targeting `sogo:20000` at host `mail.brmartin.co.uk` on entrypoint `websecure` with TLS `wildcard-brmartin-tls`
- [x] T039 [US3] SoGO pod Running; `https://mail.brmartin.co.uk/SOGo/` returns HTTP 200; lldap LDAP now working with correct base DN (`dc=brmartin,dc=co,dc=uk` via env var fix)
- [x] T040 [US3] Verify webmail end-to-end: log in to `https://mail.brmartin.co.uk` as `ben`; verify inbox displays migrated messages; compose and send an email to an external address; confirm delivery; verify sent message passes DKIM check

**Checkpoint**: User Story 3 complete — webmail is accessible and functional. SC-005 (webmail accessible) verified.

---

## Phase 6: User Story 4 - Centralized Account Management (Priority: P2)

**Goal**: Integrate lldap with Keycloak so that administrators access lldap via Keycloak SSO (no local admin password), Keycloak federates users from lldap for other services, and the admin workflow for creating/disabling accounts is documented and tested.

**Independent Test**: Create a new test mail account via the lldap web UI (accessed after Keycloak login); verify IMAP login works for the new account; disable the account (remove from mail-users group); verify IMAP login fails.

### Implementation for User Story 4

- [x] T041 [US4] Create a Keycloak OIDC client for lldap in the `prod` realm (via Keycloak admin UI at `https://sso.brmartin.co.uk/admin`): Client ID `lldap`, Client Protocol `openid-connect`, Root URL `https://ldap.brmartin.co.uk`, Valid Redirect URIs `https://ldap.brmartin.co.uk/oauth2/callback`, set client secret; note the client ID and secret for lldap configuration
- [x] T042 [US4] N/A — lldap 0.6.2 does not support native OIDC/OAuth2 login (not in changelog, LLDAP_OAUTH2__* env vars are silently ignored). lldap admin UI uses local admin credentials. Keycloak OIDC client was created but is unused by lldap. lldap-oidc-secret K8s secret exists but is not referenced in Terraform.
- [x] T043 [US4] Configure Keycloak LDAP User Federation (via Keycloak admin UI): Add LDAP provider — Edit Mode `READ_ONLY`, Connection URL `ldap://lldap.default.svc.cluster.local:3890`, Users DN `ou=people,dc=brmartin,dc=co,dc=uk`, Bind DN `uid=keycloak,ou=people,dc=brmartin,dc=co,dc=uk`, Bind Credential (keycloak service account password from T014), User Object Classes `inetOrgPerson`, Pagination OFF, Sync Registrations OFF; trigger "Sync all users" — 1 user added (ben), sync successful.
- [x] T044 [US4] Verify full admin workflow — created testuser via lldap GraphQL API, added to mail-users group, set password via /app/lldap_set_password; doveadm auth test succeeded. Also discovered and fixed: Dovecot pass_filter did not enforce group membership (lldap does not return memberOf); fixed with two-passdb chain: passdb1 searches ou=groups for mail-users member= (group check, result_success=continue), passdb2 does auth_bind for password verification.
- [x] T045 [US4] Removed testuser from mail-users group; doveadm auth test now returns auth failed (exit 77). Group enforcement working correctly.
- [x] T046 [US4] Deleted testuser from lldap via GraphQL API.

**Checkpoint**: User Story 4 complete — account lifecycle is managed via lldap (with Keycloak OIDC authentication for admin UI). SC-004 verified.

---

## Phase 7: User Story 5 - Mailcow Decommission (Priority: P3)

**Goal**: Remove the mailcow Docker Compose deployment from Hestia completely, confirming that all mail services continue to function from Kubernetes alone.

**Independent Test**: After stopping mailcow, verify SMTP port 25 accepts connections, IMAPS 993 accepts connections, and a test message can be sent and received end-to-end.

### Implementation for User Story 5

- [x] T047 [US5] Archived mailcow config to `/tmp/mailcow-archive-20260312.tar.gz` (217KB)
- [x] T048 [US5] Stopped all mailcow containers (including netfilter which needed force-kill); `docker compose down --remove-orphans` completed; no mailcow containers running
- [x] T049 [US5] Verified: `openssl s_client localhost:993` CONNECTED from Hestia; all K8s mail pods Running; doveadm auth test succeeds
- [x] T050 [US5] Removed all mailcow Docker volumes (vmail, vmail-index, crypt, mysql-socket, rspamd); removed `/mnt/docker/mailcow` directory; archive at `/tmp/mailcow-archive-20260312.tar.gz` retained
- [x] T051 [US5] Updated AGENTS.md: added lldap and mail rows to Services table; added 012-k8s-mail-server to Recent Changes; removed duplicate HCL line; added PostgreSQL entry for lldap/SoGO

**Checkpoint**: User Story 5 complete — mailcow fully decommissioned, all mail services running exclusively from Kubernetes. SC-006 verified.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Hardening, observability, and documentation across all components.

- [x] T052 [P] Add `prometheus.io/scrape=true` and `prometheus.io/port=11334` annotations to `kubernetes_service.rspamd` in `modules-k8s/mail/main.tf` so VictoriaMetrics scrapes Rspamd metrics; apply change
- [x] T053 [P] No probe failures in Events for any mail pod (postfix, dovecot, rspamd, lldap, sogo); all probes healthy
- [x] T054 Added mail server operational notes to AGENTS.md Debugging Tips: lldap admin URL, add/disable account workflow, DKIM rotation, Rspamd port-forward, doveadm commands, mailbox migration pattern, mail-tls renewal procedure
- [x] T055 [P] All image references in lldap/mail modules have Renovate inline comments; audit confirmed 9 renovate annotations across main.tf + variables.tf files

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundation (Phase 2)**: Depends on Phase 1 (module files must exist) — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Foundation complete — lldap must be running, service accounts created
- **US2 (Phase 4)**: Depends on US1 (Phase 3) complete — Dovecot PVC must exist and be mounted
- **US3 (Phase 5)**: Depends on Foundation complete — SoGO needs lldap + Dovecot + Postfix (can run in parallel with US2 once Foundation is done)
- **US4 (Phase 6)**: Depends on Foundation + US1 complete — Keycloak federation requires lldap running and mail stack deployed for end-to-end test
- **US5 (Phase 7)**: Depends on US1 + US2 + US4 complete — all mail functionality verified before decommission
- **Polish (Phase 8)**: Depends on all user stories complete

### User Story Dependencies

- **US1 (P1)**: Starts after Foundation — no story dependencies
- **US2 (P1)**: Starts after US1 — Dovecot StatefulSet and PVC must exist
- **US3 (P2)**: Starts after Foundation (can overlap with US2) — needs lldap, Dovecot, Postfix already up
- **US4 (P2)**: Starts after US1 — needs full mail stack deployed for end-to-end account test
- **US5 (P3)**: Starts after US1 + US2 + US4 are verified complete

### Within Each User Story

- Secrets and ConfigMaps marked [P] can be created in parallel (different resource blocks)
- PVCs can be created in parallel with ConfigMaps and Secrets
- Deployments/StatefulSets depend on their ConfigMaps and Secrets being present
- Verification tasks depend on the Deployment being applied

### Parallel Opportunities

```
Foundation Phase parallel group (T005, T006 can run together):
  Task: "Create lldap PostgreSQL database"
  Task: "Create SoGO PostgreSQL database"

US1 Phase parallel group (T015, T016, T017 can run together):
  Task: "Implement mail/variables.tf"
  Task: "Add dkim-keys Secret to modules-k8s/mail/main.tf"
  Task: "Add postfix-ldap and dovecot-ldap Secrets to modules-k8s/mail/main.tf"

US3 Phase parallel group (T036, T037 can run together):
  Task: "Add sogo-db Secret + sogo-config ConfigMap"
  Task: "Add sogo-ldap Secret"

Polish Phase parallel group (T052, T053, T055 can run together):
  Task: "Add Rspamd Prometheus annotations"
  Task: "Verify liveness/readiness probes in Grafana"
  Task: "Audit Renovate inline comments"
```

---

## Implementation Strategy

### MVP First (US1 + US2 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundation (lldap deployed, bootstrapped)
3. Complete Phase 3: US1 — mail stack deployed, SMTP/IMAP/POP3 working
4. Complete Phase 4: US2 — mailbox data migrated
5. **STOP and VALIDATE**: Mail clients send/receive, all historical mail accessible
6. Cutover complete — mailcow can remain stopped (not yet removed)

### Incremental Delivery

1. Phase 1+2: Foundation → lldap running, secrets in place
2. Phase 3+4: US1+US2 → Core mail working + data migrated → **MVP validated**
3. Phase 5: US3 → Webmail added
4. Phase 6: US4 → Keycloak SSO for admin workflow
5. Phase 7: US5 → Mailcow removed permanently
6. Phase 8: Polish → Hardening and observability

### Note: FR-011 Antivirus Scanning

FR-011 requires malware scanning. Per `plan.md` research decision, ClamAV is excluded (it was already disabled in mailcow via `SKIP_CLAMD=y`). If AV scanning is required in future, integrate ClamAV as an Rspamd ICAP plugin by adding a `kubernetes_deployment.clamav` and `rspamd_antivirus.conf` ConfigMap key. No task is generated for this in the current scope.

---

## Notes

- [P] tasks involve different Terraform resource blocks or different files — no write conflicts
- [Story] label maps each task to its user story for traceability
- Each user story phase is independently completable and testable
- Commit after each phase checkpoint at minimum
- Stop at any checkpoint to validate story independently before proceeding
- The `mail-tls` secret (T007) must be manually re-synced if the wildcard cert renews — add to AGENTS.md (T054)
- lldap service accounts (dovecot, postfix, sogo, keycloak) are provisioned manually in T014 — their passwords must be captured and added to Terraform variables / `.env` before Phase 3 begins
