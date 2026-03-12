# Quickstart: Kubernetes Mail Server Migration

**Feature**: 012-k8s-mail-server  
**Branch**: `012-k8s-mail-server`

This document is the operator runbook for deploying and migrating to the new Kubernetes mail stack.

---

## Prerequisites

1. Terraform environment loaded: `set -a && source .env && set +a`
2. kubectl configured (KUBECONFIG set in shell)
3. SSH access to Hestia: `/usr/bin/ssh 192.168.1.5`
4. Keycloak admin access: https://sso.brmartin.co.uk
5. lldap web UI will be at: https://ldap.brmartin.co.uk (after deploy)
6. Wildcard TLS secret available in `default` namespace (verify: `kubectl get secret wildcard-brmartin-tls -n default`)
7. External PostgreSQL accessible: `192.168.1.10:5433` (verify: `psql -h 192.168.1.10 -p 5433 -U postgres`)

---

## Deployment Order

The components have dependencies that require this deployment sequence:

```
1. lldap (identity)
   ↓
2. Mail stack (mail, depends on lldap)
   ↓
3. Keycloak federation (manual, via Keycloak admin UI)
   ↓
4. Data migration (during planned downtime)
   ↓
5. Validation
   ↓
6. Mailcow decommission
```

---

## Step 1: Pre-Migration Data Extraction (run before any downtime)

**Extract DKIM private keys from mailcow Redis** (run on Hestia):

```bash
/usr/bin/ssh 192.168.1.5 "
  REDISPASS=\$(grep REDISPASS /mnt/docker/mailcow/mailcow.conf | cut -d= -f2)
  docker exec mailcowdockerized-redis-mailcow-1 \
    redis-cli -a \$REDISPASS HGET DKIM_PRIV_KEYS 'dkim.brmartin.co.uk' > /tmp/dkim-brmartin.key
  docker exec mailcowdockerized-redis-mailcow-1 \
    redis-cli -a \$REDISPASS HGET DKIM_PRIV_KEYS 'dkim.martinilink.co.uk' > /tmp/dkim-martinilink.key
  echo 'Keys written to /tmp/dkim-*.key'
"
```

Store these keys as Kubernetes Secrets:
```bash
kubectl create secret generic dkim-keys -n default \
  --from-file=brmartin.co.uk.dkim.key=/tmp/dkim-brmartin.key \
  --from-file=martinilink.co.uk.dkim.key=/tmp/dkim-martinilink.key
```

**Verify DKIM DNS** (the `dkim` selector must remain in DNS):
```bash
dig TXT dkim._domainkey.brmartin.co.uk
dig TXT dkim._domainkey.martinilink.co.uk
```

---

## Step 2: Deploy lldap

```bash
terraform plan -target='module.k8s_lldap' -out=tfplan
terraform apply tfplan
```

Verify lldap is running:
```bash
kubectl get pods -n default -l app=lldap
kubectl logs -n default -l app=lldap --tail=20
```

Access lldap web UI: https://ldap.brmartin.co.uk

**Create service accounts in lldap** (via web UI or lldap API):
- `dovecot` — service account for Dovecot
- `postfix` — service account for Postfix  
- `sogo` — service account for SoGO
- `keycloak` — service account for Keycloak federation

**Create group and mail user in lldap**:
1. Create group: `mail-users`
2. Create user: `ben` with `mail=ben@brmartin.co.uk`
3. Add `ben` to `mail-users` group
4. Set a password for `ben` (user must know this — it replaces the mailcow password)

---

## Step 3: Configure Keycloak Federation (manual, via Keycloak admin UI)

1. Log into Keycloak admin: https://sso.brmartin.co.uk/admin
2. Select realm `prod`
3. Navigate to **User Federation** → **Add provider** → **LDAP**
4. Configure:
   - Edit Mode: `READ_ONLY`
   - Vendor: `Other`
   - Connection URL: `ldap://lldap.default.svc.cluster.local:3890`
   - Users DN: `ou=people,dc=brmartin,dc=co,dc=uk`
   - Bind Type: `simple`
   - Bind DN: `uid=keycloak,ou=people,dc=brmartin,dc=co,dc=uk`
   - Bind Credential: (keycloak service account password from lldap)
   - Username LDAP attribute: `uid`
   - UUID LDAP attribute: `uid`
   - User object classes: `inetOrgPerson`
   - **Sync Registrations: OFF**
   - **Pagination: OFF**
5. Save and trigger **Sync all users** — verify lldap users appear in Keycloak

---

## Step 4: Deploy Mail Stack

```bash
terraform plan -target='module.k8s_mail' -out=tfplan
terraform apply tfplan
```

Verify all pods are running:
```bash
kubectl get pods -n default -l app.kubernetes.io/part-of=mail
```

Expected pods:
- `postfix-0` — Running
- `dovecot-0` — Running
- `rspamd-*` — Running
- `mail-redis-*` — Running
- `sogo-*` — Running

Check logs for startup errors:
```bash
kubectl logs -n default postfix-0 --tail=30
kubectl logs -n default dovecot-0 --tail=30
kubectl logs -n default -l app=rspamd --tail=30
```

---

## Step 5: Mail Data Migration (planned downtime)

### 5a. Stop mailcow SMTP (start of downtime)

```bash
/usr/bin/ssh 192.168.1.5 "
  cd /mnt/docker/mailcow
  docker stop mailcowdockerized-postfix-mailcow-1 mailcowdockerized-dovecot-mailcow-1
"
```

External MTAs will now queue mail for `brmartin.co.uk` and retry for 5 days.

### 5b. rsync mailboxes to new Dovecot PVC

Identify the Dovecot PVC mount path on a node:
```bash
kubectl get pvc dovecot-mailboxes -n default -o jsonpath='{.spec.volumeName}'
# → pvc-<uuid>

# Find the NFS path on Hestia
/usr/bin/ssh 192.168.1.5 "ls /storage/v/ | grep mail"
```

Rsync the mailbox data:
```bash
/usr/bin/ssh 192.168.1.5 "
  rsync -av --chown=5000:5000 --preserve-permissions -A -X \
    /var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data/ \
    /storage/v/glusterfs_dovecot-mailboxes_data/
"
```

**Verify** the rsync completed without errors and the Maildir structure is intact:
```bash
/usr/bin/ssh 192.168.1.5 "find /storage/v/glusterfs_dovecot-mailboxes_data/ -maxdepth 4 -type d"
```

### 5c. Validate mail reception

Send a test message to `ben@brmartin.co.uk` from an external mail provider. Check it appears in the new Dovecot mailbox:
```bash
kubectl exec -n default dovecot-0 -- doveadm mailbox list -u ben
kubectl exec -n default dovecot-0 -- doveadm fetch -u ben text mailbox INBOX ALL | tail -50
```

### 5d. Validate SMTP sending

Send an outbound test email via the new Postfix:
```bash
kubectl exec -n default postfix-0 -- sendmail -v ben@example.com <<EOF
Subject: Test
Test message from new mail stack
EOF
```

Check mail-tester.com score (should pass SPF, DKIM, DMARC):
- Send a test to the mail-tester.com unique address
- Score should be ≥ 8/10

---

## Step 6: Validate All Protocols

### IMAP (external access)

```bash
# From an external machine or using openssl:
openssl s_client -connect mail.brmartin.co.uk:993
# Expected: TLS handshake → Dovecot greeting
```

### POP3

```bash
openssl s_client -connect mail.brmartin.co.uk:995
# Expected: TLS handshake → Dovecot POP3 greeting
```

### SMTP submission

```bash
openssl s_client -starttls smtp -connect mail.brmartin.co.uk:587
# Expected: EHLO + AUTH PLAIN/LOGIN in SASL capabilities
```

### Webmail

- Navigate to https://mail.brmartin.co.uk
- Log in with `ben` / (new lldap password)
- Verify inbox contents match pre-migration snapshot

---

## Step 7: Spam Filter Verification

Send a GTUBE test message (standard spam test string):
```
XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X
```

Verify it is rejected or placed in Junk and does NOT appear in inbox.

Check Rspamd web UI (if enabled):
```bash
kubectl port-forward -n default svc/rspamd 11334:11334
# → http://localhost:11334
```

---

## Step 8: Decommission Mailcow

Only after all validation steps pass:

```bash
/usr/bin/ssh 192.168.1.5 "
  cd /mnt/docker/mailcow
  docker compose down
"
```

Verify mail services still operational after stopping mailcow:
```bash
# SMTP still accepts connections:
nc -z 192.168.1.5 25 && echo "SMTP OK"
nc -z 192.168.1.5 587 && echo "Submission OK"

# IMAP still accepts connections:
nc -z 192.168.1.5 993 && echo "IMAPS OK"
```

Archive the mailcow data before removal:
```bash
/usr/bin/ssh 192.168.1.5 "
  sudo tar -czf /tmp/mailcow-backup-\$(date +%Y%m%d).tar.gz \
    /mnt/docker/mailcow/mailcow.conf \
    /mnt/docker/mailcow/data/conf/
  echo 'Backup at /tmp/mailcow-backup-*.tar.gz'
"
```

---

## Rollback Plan

If the new stack fails during migration:

1. Start mailcow SMTP again: `docker start mailcowdockerized-postfix-mailcow-1`
2. The K8s Postfix pod and mailcow Postfix will conflict on port 25 — stop the K8s Postfix: `kubectl scale statefulset postfix -n default --replicas=0`
3. Diagnose the issue; retry migration when resolved

---

## Verification Checklist

- [ ] DKIM private keys extracted and stored as K8s Secret
- [ ] lldap deployed and accessible at https://ldap.brmartin.co.uk
- [ ] Mail user `ben` created in lldap with correct `mail` attribute
- [ ] Keycloak federation configured; lldap users visible in Keycloak
- [ ] Mail stack deployed; all 5 pods Running
- [ ] Mailbox data rsync'd; folder structure verified
- [ ] SMTP inbound delivery tested (external sender → inbox)
- [ ] SMTP outbound tested (passes SPF, DKIM, DMARC on mail-tester.com)
- [ ] IMAP accessible externally (port 993)
- [ ] POP3 accessible externally (port 995)
- [ ] Webmail accessible at https://mail.brmartin.co.uk
- [ ] Spam filter rejects GTUBE test
- [ ] Mailcow Docker Compose stopped; ports still functional
- [ ] Mailcow data archived; Docker Compose stack removed

---

## Useful Commands

```bash
# Mail queue inspection
kubectl exec -n default postfix-0 -- mailq

# Force mail queue flush
kubectl exec -n default postfix-0 -- postqueue -f

# List Dovecot users
kubectl exec -n default dovecot-0 -- doveadm user '*'

# Check Dovecot authentication
kubectl exec -n default dovecot-0 -- doveadm auth test ben mypassword

# Rspamd stats
kubectl exec -n default -l app=rspamd -- rspamc stat

# lldap API (GraphQL)
# https://ldap.brmartin.co.uk/api/graphql (authenticated)
```
