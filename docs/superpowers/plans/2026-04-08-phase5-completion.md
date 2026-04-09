# Phase 5 Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all four outstanding Phase 5 issues from the SeaweedFS migration: make mas config.yaml reproducible, resolve plex-backup size gap, rotate per-service S3 identities, and verify athenaeum-backend stability.

**Architecture:** Infrastructure-only work in an existing Terraform-managed k3s cluster (`iac/cluster-state`). Secrets are patched via `kubectl` (per `feedback_secrets_from_kube.md` — never in TF variables). Deployments use the standard `config-processor` init container pattern already established for synapse. S3 identities on SeaweedFS are managed via `weed shell` `s3.configure`.

**Tech Stack:** Terraform (`hashicorp/kubernetes`, `gavinbunney/kubectl`), k3s 1.34, SeaweedFS S3 gateway, matrix-authentication-service, busybox init containers, `kubectl` for out-of-band secret patches.

---

## File Structure

**Modify:**
- `modules-k8s/matrix/main.tf` — add `mas_config_template` ConfigMap, add init container + secret volume to `kubernetes_deployment.mas`, delete `kubernetes_persistent_volume_claim.mas_config`
- `modules-k8s/matrix/secrets.tf` — update comment listing secret keys

**Create:**
- `docs/seaweedfs-s3-identities.md` — operator runbook for SW identity management (new doc, referenced from migration doc)

**Out-of-band (not version-controlled):**
- `matrix-secrets` — add `mas_key_rsa`, `mas_key_ec_p256`, `mas_key_ec_p384`, `mas_key_ec_k256`, `mas_smtp_password`
- Various `*-s3` / `*-secrets` — rotate SW access keys (Task 3)
- SeaweedFS `s3.configure` — create per-service identities (Task 3)

---

## Task 1: Reproducible mas config.yaml

**Files:**
- Modify: `modules-k8s/matrix/main.tf:227-242` (delete mas_config PVC), `:519-605` (mas deployment)
- Modify: `modules-k8s/matrix/secrets.tf:1-6` (update comment)

**Design:** Mirror the synapse `config-processor` pattern. ConfigMap holds the non-secret scaffold with `__PLACEHOLDER__` markers. Init container `sed`s single-line secrets in from env vars. Signing keys are mounted as files from `matrix-secrets` and referenced via MAS's native `key_file:` syntax, avoiding multiline sed. Rendered config lands in an `emptyDir` at `/config`.

- [ ] **Step 1.1: Back up the current mas config.yaml content**

Run:
```bash
kubectl -n default delete pod mas-backup --ignore-not-found --wait=true
kubectl -n default apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: mas-backup, namespace: default }
spec:
  restartPolicy: Never
  containers:
  - name: x
    image: busybox:1
    command: ["sh","-c","cp /mnt/synapse-mas/config.yaml /tmp/ && sleep 30"]
    volumeMounts: [{ name: c, mountPath: /mnt }]
  volumes:
  - name: c
    persistentVolumeClaim: { claimName: matrix-config-sw }
YAML
kubectl -n default wait --for=condition=Ready pod/mas-backup --timeout=60s
kubectl -n default cp mas-backup:/tmp/config.yaml /tmp/mas-config-pre-refactor.yaml
kubectl -n default delete pod mas-backup --wait=false
wc -l /tmp/mas-config-pre-refactor.yaml  # expect: 130
```

- [ ] **Step 1.2: Extract signing keys from the backed-up config into separate PEM files**

Run:
```bash
python3 - <<'PY'
import yaml, pathlib
d = yaml.safe_load(open("/tmp/mas-config-pre-refactor.yaml"))
for e in d["secrets"]["keys"]:
    pathlib.Path(f"/tmp/mas-{e['kid']}.pem").write_text(e["key"])
    print(e["kid"], len(e["key"]))
PY
ls -la /tmp/mas-*.pem  # expect 4 files
```

- [ ] **Step 1.3: Patch matrix-secrets with signing keys + smtp password**

The RSA key has kid `TPieyaE3PM`, the EC keys `OeZlPcc37E` (ES256), `XctwrElhF9` (ES384), `Bjvh15mokX` (ES256K). The kid strings become stable identifiers — keep them in the ConfigMap template.

Run:
```bash
SMTP_PW=$(python3 -c 'import yaml; print(yaml.safe_load(open("/tmp/mas-config-pre-refactor.yaml"))["email"]["password"])')
kubectl -n default patch secret matrix-secrets --type=json -p="[
  {\"op\":\"add\",\"path\":\"/data/mas_key_rsa\",\"value\":\"$(base64 -w0 /tmp/mas-TPieyaE3PM.pem)\"},
  {\"op\":\"add\",\"path\":\"/data/mas_key_ec_p256\",\"value\":\"$(base64 -w0 /tmp/mas-OeZlPcc37E.pem)\"},
  {\"op\":\"add\",\"path\":\"/data/mas_key_ec_p384\",\"value\":\"$(base64 -w0 /tmp/mas-XctwrElhF9.pem)\"},
  {\"op\":\"add\",\"path\":\"/data/mas_key_ec_k256\",\"value\":\"$(base64 -w0 /tmp/mas-Bjvh15mokX.pem)\"},
  {\"op\":\"add\",\"path\":\"/data/mas_smtp_password\",\"value\":\"$(printf '%s' "$SMTP_PW" | base64 -w0)\"}
]"
kubectl -n default get secret matrix-secrets -o jsonpath='{.data}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d.keys()))'
# Expect keys to include: mas_key_rsa, mas_key_ec_p256, mas_key_ec_p384, mas_key_ec_k256, mas_smtp_password
```

- [ ] **Step 1.4: Add mas_config_template ConfigMap to matrix/main.tf**

Insert a new resource after the synapse `kubernetes_config_map.synapse_config` block (around line 187). The scaffold mirrors the PVC config but uses placeholders for single-line secrets and `key_file:` paths for signing keys.

Add to `modules-k8s/matrix/main.tf`:

```hcl
resource "kubernetes_config_map" "mas_config" {
  metadata {
    name      = "mas-config-template"
    namespace = var.namespace
    labels    = local.mas_labels
  }

  data = {
    "config.yaml" = <<-EOF
      http:
        listeners:
        - name: web
          resources:
          - name: health
          - name: discovery
          - name: human
          - name: oauth
          - name: compat
          - name: graphql
            playground: true
          - name: assets
          binds:
          - host: 0.0.0.0
            port: 8081
          proxy_protocol: false
        trusted_proxies:
          - 10.42.0.0/16
          - 0.0.0.0
        public_base: https://${var.mas_hostname}/
        issuer: https://${var.mas_hostname}/
      database:
        username: mas_user
        password: "MAS_DB_PASSWORD_PLACEHOLDER"
        database: mas
        host: ${var.db_host}
        port: ${var.db_port}
        max_connections: 10
        min_connections: 0
        connect_timeout: 30
        idle_timeout: 600
        max_lifetime: 1800
      matrix:
        homeserver: ${var.server_name}
        secret: "MAS_ADMIN_TOKEN_PLACEHOLDER"
        endpoint: http://synapse.${var.namespace}.svc.cluster.local:8008
      email:
        from: '"Authentication Service" <services@${var.server_name}>'
        reply_to: '"Authentication Service" <services@${var.server_name}>'
        transport: smtp
        mode: starttls
        hostname: mail.${var.server_name}
        port: 587
        username: svc-matrix
        password: "MAS_SMTP_PASSWORD_PLACEHOLDER"
      secrets:
        encryption: "MAS_ENCRYPTION_PLACEHOLDER"
        keys:
        - kid: TPieyaE3PM
          key_file: /keys/mas_key_rsa
        - kid: OeZlPcc37E
          key_file: /keys/mas_key_ec_p256
        - kid: XctwrElhF9
          key_file: /keys/mas_key_ec_p384
        - kid: Bjvh15mokX
          key_file: /keys/mas_key_ec_k256
      passwords:
        enabled: false
      clients:
        - client_id: 0000000000000000000SYNAPSE
          client_auth_method: client_secret_basic
          client_secret: "MAS_CLIENT_SECRET_PLACEHOLDER"
      upstream_oauth2:
        providers:
          - id: "01HVV3NYJQRY4Y15PWNQ6J2DXR"
            issuer: "https://sso.${var.server_name}/realms/prod"
            human_name: "brmartin SSO"
            token_endpoint_auth_method: client_secret_basic
            client_id: "mas"
            client_secret: "MAS_KEYCLOAK_CLIENT_SECRET_PLACEHOLDER"
            scope: "openid profile email"
            discovery_mode: oidc
            claims_imports:
              localpart:
                action: require
                template: "{{ user.preferred_username }}"
              displayname:
                action: suggest
                template: "{{ user.name }}"
              email:
                action: suggest
                template: "{{ user.email }}"
                set_email_verification: always
      policy:
        data:
          admin_users:
            - ben
    EOF
  }
}
```

**Verification:** The template byte-for-byte matches the current PVC config.yaml except: (a) secrets are placeholders/key_file refs, (b) hardcoded `brmartin.co.uk` replaced with `${var.server_name}`, (c) hardcoded `mas.brmartin.co.uk` replaced with `${var.mas_hostname}`, (d) `synapse.default...` replaced with `synapse.${var.namespace}...`.

- [ ] **Step 1.5: Replace mas deployment spec (init container + emptyDir + key mounts)**

Replace the entire `resource "kubernetes_deployment" "mas"` block (`modules-k8s/matrix/main.tf:519-605`) with:

```hcl
resource "kubernetes_deployment" "mas" {
  metadata {
    name      = "mas"
    namespace = var.namespace
    labels    = local.mas_labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = local.mas_labels
    }

    template {
      metadata {
        labels      = local.mas_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        init_container {
          name    = "config-processor"
          image   = "busybox:1.37"
          command = ["/bin/sh", "-c"]
          args = [<<-EOF
            cp /config-template/config.yaml /config/config.yaml
            sed -i "s|MAS_DB_PASSWORD_PLACEHOLDER|$MAS_DB_PASSWORD|g" /config/config.yaml
            sed -i "s|MAS_ADMIN_TOKEN_PLACEHOLDER|$MAS_ADMIN_TOKEN|g" /config/config.yaml
            sed -i "s|MAS_SMTP_PASSWORD_PLACEHOLDER|$MAS_SMTP_PASSWORD|g" /config/config.yaml
            sed -i "s|MAS_ENCRYPTION_PLACEHOLDER|$MAS_ENCRYPTION|g" /config/config.yaml
            sed -i "s|MAS_CLIENT_SECRET_PLACEHOLDER|$MAS_CLIENT_SECRET|g" /config/config.yaml
            sed -i "s|MAS_KEYCLOAK_CLIENT_SECRET_PLACEHOLDER|$MAS_KEYCLOAK_CLIENT_SECRET|g" /config/config.yaml
          EOF
          ]

          env {
            name = "MAS_DB_PASSWORD"
            value_from {
              secret_key_ref { name = "matrix-secrets", key = "mas_db_password" }
            }
          }
          env {
            name = "MAS_ADMIN_TOKEN"
            value_from {
              secret_key_ref { name = "matrix-secrets", key = "mas_admin_token" }
            }
          }
          env {
            name = "MAS_SMTP_PASSWORD"
            value_from {
              secret_key_ref { name = "matrix-secrets", key = "mas_smtp_password" }
            }
          }
          env {
            name = "MAS_ENCRYPTION"
            value_from {
              secret_key_ref { name = "matrix-secrets", key = "mas_encryption_secret" }
            }
          }
          env {
            name = "MAS_CLIENT_SECRET"
            value_from {
              secret_key_ref { name = "matrix-secrets", key = "mas_client_secret" }
            }
          }
          env {
            name = "MAS_KEYCLOAK_CLIENT_SECRET"
            value_from {
              secret_key_ref { name = "matrix-secrets", key = "mas_keycloak_client_secret" }
            }
          }

          volume_mount {
            name       = "config-template"
            mount_path = "/config-template"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }

        container {
          name  = "mas"
          image = "${var.mas_image}:${var.mas_tag}"

          port {
            container_port = 8081
          }

          env {
            name  = "MAS_CONFIG"
            value = "/config/config.yaml"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "keys"
            mount_path = "/keys"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8081
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8081
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        volume {
          name = "config-template"
          config_map {
            name = kubernetes_config_map.mas_config.metadata[0].name
          }
        }
        volume {
          name = "config"
          empty_dir {}
        }
        volume {
          name = "keys"
          secret {
            secret_name = "matrix-secrets"
            items {
              key  = "mas_key_rsa"
              path = "mas_key_rsa"
            }
            items {
              key  = "mas_key_ec_p256"
              path = "mas_key_ec_p256"
            }
            items {
              key  = "mas_key_ec_p384"
              path = "mas_key_ec_p384"
            }
            items {
              key  = "mas_key_ec_k256"
              path = "mas_key_ec_k256"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.mas_config,
  ]
}
```

- [ ] **Step 1.6: Delete mas_config PVC resource from TF**

Delete `resource "kubernetes_persistent_volume_claim" "mas_config"` block at `modules-k8s/matrix/main.tf:227-242`. First remove it from state so the cluster object survives as rollback insurance:

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
terraform state rm 'module.k8s_matrix.kubernetes_persistent_volume_claim.mas_config'
# Then remove the block from main.tf via Edit tool
```

- [ ] **Step 1.7: Update matrix/secrets.tf comment**

Edit `modules-k8s/matrix/secrets.tf` to add the new keys to the documented list:

```hcl
# Matrix secrets are managed outside Terraform as a plain Kubernetes Secret.
# Secret name: matrix-secrets
# Keys: as_token, db_password, form_secret, hs_token, macaroon_secret_key,
#        mas_admin_token, mas_client_secret, mas_db_password, mas_encryption_secret,
#        mas_key_ec_k256, mas_key_ec_p256, mas_key_ec_p384, mas_key_rsa,
#        mas_keycloak_client_secret, mas_smtp_password, registration_shared_secret,
#        smtp_password, turn_shared_secret
```

- [ ] **Step 1.8: Plan and apply**

Run:
```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
terraform plan -target=module.k8s_matrix
# Expect: 1 add (mas_config ConfigMap), 1 change (mas deployment), 1 destroy (already removed from state, so should be 0 destroy — if 1 destroy appears for the PVC, STOP and fix state)
terraform apply -target=module.k8s_matrix -auto-approve
```

- [ ] **Step 1.9: Verify mas pod recovery**

Run:
```bash
kubectl -n default rollout status deploy/mas --timeout=120s
kubectl -n default get pod -l app=matrix,component=mas -o wide
kubectl -n default logs -l app=matrix,component=mas --tail=30
# Expect: health checks returning 200, no config load errors
curl -sf https://mas.brmartin.co.uk/health && echo OK
```

If the pod crashloops: `kubectl logs` the init container (`-c config-processor`) first, then the main container. The backed-up `/tmp/mas-config-pre-refactor.yaml` is the ground truth for comparison.

- [ ] **Step 1.10: Commit**

```bash
cd /home/ben/Documents/Personal/projects/iac/cluster-state
git add modules-k8s/matrix/main.tf modules-k8s/matrix/secrets.tf
git commit -m "$(cat <<'EOF'
feat(matrix): template mas config.yaml from matrix-secrets

Adds init container pattern matching synapse's config-processor. Config
template lives in a ConfigMap; single-line secrets are sed-substituted
from matrix-secrets env vars; RSA/EC signing keys are mounted as files
and referenced via MAS's native key_file syntax.

Closes the architectural gap where mas config.yaml lived unmanaged on
the matrix-config-sw PVC with no reproducibility path.
EOF
)"
```

---

## Task 2: Resolve plex-backup size gap

**Files:** No code changes. Documentation + decision only.

**Finding (verified 2026-04-08):**
- MinIO `plex-backup/blobs/`: 89 GiB / 2678 obj (historical, pre-cutover)
- MinIO `plex-backup/library/`: 343 GiB / 2693 obj (historical, pre-cutover; oldest object 2026-01-29)
- SW `plex-backup/blobs/`: ~48 obj × 56 MiB = ~2.7 GiB (rolling window)
- SW `plex-backup/library/`: ~48 obj × 135 MiB = ~6.4 GiB (rolling window)

The plex-db-backup cronjob runs every 30 min and cleans up keeping 48 objects per prefix (24h retention). Before cutover it wrote to MinIO; since 2026-04-07 10:00 UTC it writes to SW. The cleanup function only deletes objects at the **current** endpoint — so old MinIO backups are frozen orphans.

**Decision: do not mirror.** Rationale:
1. Plex is functional on current SW backups.
2. The MinIO data is obsolete (Plex database state has diverged).
3. Restic covers Plex's live PVC going forward.
4. Phase 6 MinIO teardown drops all historical buckets; mirroring this 432 GiB would just be deferred deletion.

- [ ] **Step 2.1: Document the decision in docs/seaweedfs-migration.md**

Add to the Phase 5 section after the existing bucket audit notes:

```markdown
### Plex-backup historical data

MinIO `plex-backup` contains 432 GiB of pre-cutover historical backups
(blobs/ and library/ prefixes, oldest 2026-01-29). These will be
dropped in Phase 6 along with MinIO. Not mirrored to SeaweedFS
because:

- Current SW backups are functional (48-object rolling window per prefix)
- Historical Plex DB state has diverged; recovery value is ~zero
- Restic covers the live PVC going forward
```

- [ ] **Step 2.2: Commit**

```bash
git add docs/seaweedfs-migration.md
git commit -m "docs(seaweedfs): document plex-backup historical data decision"
```

---

## Task 3: Rotate per-service SeaweedFS S3 identities

**Files:**
- Create: `docs/seaweedfs-s3-identities.md`
- No TF changes (secrets managed out-of-band)

**Design:** SeaweedFS `s3.configure` supports per-identity `buckets` + `actions` scoping. Create one identity per consumer, each limited to its own bucket(s). Update the corresponding `*-s3` / `*-secrets` k8s secrets via `kubectl patch` and trigger rollouts. The existing `admin` identity stays for ops use only.

**Service → bucket → secret mapping (verified 2026-04-08):**

| Service | Bucket(s) | K8s Secret | Secret keys |
|---|---|---|---|
| loki | `loki` | `loki-s3` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` |
| victoriametrics | `victoriametrics` | `victoriametrics-s3` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` |
| media-centre | `plex-backup` | `media-centre-secrets` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` |
| athenaeum | `athenaeum-attachments` | `athenaeum-secrets` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` |
| gitlab-runner | `gitlab-runner-cache` | `gitlab-runner-cache-s3` | (verify key names) |
| overseerr | `overseerr-litestream` | (verify secret name) | (verify key names) |

- [ ] **Step 3.1: Verify the full consumer list**

Run:
```bash
kubectl -n default get secrets | grep -iE 's3$|-s3 |minio|secrets$' | awk '{print $1}' | while read s; do
  echo "--- $s ---"
  kubectl -n default get secret "$s" -o jsonpath='{.data}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d.keys()))'
done
```

Cross-check with `grep -r 'seaweedfs-s3\|MINIO_ENDPOINT\|s3_endpoint' modules-k8s/` to catch any consumers not in the table above. **Update the mapping table before proceeding.**

- [ ] **Step 3.2: Generate per-service credentials**

For each service, generate a 128-bit access key and 192-bit secret:
```bash
for svc in loki victoriametrics media-centre athenaeum gitlab-runner overseerr; do
  echo "$svc: access=$(openssl rand -hex 16) secret=$(openssl rand -hex 24)"
done > /tmp/sw-s3-creds.txt
cat /tmp/sw-s3-creds.txt
```

Stash `/tmp/sw-s3-creds.txt` until all rotations are complete. Delete after.

- [ ] **Step 3.3: Create identities in SeaweedFS**

For each service, run (replacing USER/KEY/SEC/BUCKET):
```bash
kubectl -n default exec seaweedfs-master-0 -c master -- sh -c "echo 's3.configure -apply -user USER -access_key KEY -secret_key SEC -buckets BUCKET -actions Read,Write,List,Tagging' | weed shell -master=seaweedfs-master:9333"
```

Example for loki:
```bash
kubectl -n default exec seaweedfs-master-0 -c master -- sh -c \
  "echo 's3.configure -apply -user loki -access_key <key> -secret_key <sec> -buckets loki -actions Read,Write,List,Tagging' | weed shell -master=seaweedfs-master:9333"
```

Verify:
```bash
kubectl -n default exec seaweedfs-master-0 -c master -- sh -c "echo 's3.configure' | weed shell -master=seaweedfs-master:9333" 2>&1 | tail -60
# Expect: all identities listed, each with its own bucket scope
```

- [ ] **Step 3.4: Rotate each consumer secret + bounce pods**

For each service:

```bash
SVC=loki; KEY=<new-key>; SEC=<new-sec>
kubectl -n default patch secret "${SVC}-s3" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/data/MINIO_ACCESS_KEY\",\"value\":\"$(printf %s "$KEY" | base64 -w0)\"},
  {\"op\":\"replace\",\"path\":\"/data/MINIO_SECRET_KEY\",\"value\":\"$(printf %s "$SEC" | base64 -w0)\"}
]"
# Bounce the consumer (loki, vm, overseerr, athenaeum, media-centre cron next run, gitlab-runner)
kubectl -n default rollout restart sts/loki  # adjust resource kind per service
kubectl -n default rollout status sts/loki --timeout=180s
```

**Verification per service:**
- loki: `kubectl -n default logs sts/loki -c loki --tail=20` — no `AccessDenied` errors; querier returns recent data
- victoriametrics: `kubectl -n default logs -l app=vmbackup --tail=20` — sees `uploading part{...}`
- athenaeum: new pod healthy; attachments upload works (hit UI if reachable)
- media-centre: wait for next 30-min plex-db-backup cronjob run, verify `kubectl logs job/plex-db-backup-<id>` shows no curl errors
- gitlab-runner: trigger a CI job that touches cache; verify cache hit/push
- overseerr: verify litestream logs

Do services **one at a time**. On first failure, stop and investigate — most likely causes: identity not applied (check `s3.configure` output), bucket typo in identity spec, stale pod holding old creds.

- [ ] **Step 3.5: Confirm admin identity is no longer used by workloads**

After all rotations, verify no pod still references the old admin key:
```bash
ADMIN_KEY=b419cd9ac8e2739f863a822b14454c85
kubectl -n default get secrets -o json | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
for s in d['items']:
    for k, v in (s.get('data') or {}).items():
        try:
            if base64.b64decode(v).decode(errors='ignore') == '$ADMIN_KEY':
                print(f\"{s['metadata']['name']}.{k}\")
        except: pass
"
# Expect: empty output (or only secrets intentionally retained)
```

- [ ] **Step 3.6: Write the runbook**

Create `docs/seaweedfs-s3-identities.md` documenting:
- Mapping table (updated with final values, keys redacted)
- How to create/list/delete identities via `weed shell` `s3.configure`
- Rotation procedure (reference this plan's Step 3.4)
- Admin identity use cases (emergency access, bucket creation)

- [ ] **Step 3.7: Scrub credentials and commit**

```bash
shred -u /tmp/sw-s3-creds.txt
cd /home/ben/Documents/Personal/projects/iac/cluster-state
git add docs/seaweedfs-s3-identities.md
git commit -m "docs(seaweedfs): per-service S3 identity rotation runbook"
```

---

## Task 4: Verify athenaeum-backend stability

**Files:** No code changes unless a root cause is found.

**Current state (verified 2026-04-08 11:40 UTC):**
- New pod `athenaeum-backend-944f9469f-tjbg6` is healthy, 0 restarts, created 11:27 UTC
- Old pod `athenaeum-backend-764d5bf844-kzpm2` (520 restarts over 5d16h) is gone
- Deployment has annotation `kubectl.kubernetes.io/restartedAt: 2026-04-08T12:25:13+01:00` (= 11:25 UTC) — rollout was triggered in the Phase 5 cutover session
- Container `--previous` logs unavailable (new pod has never restarted)
- Loki queries for `pod=~"athenaeum-backend-764d5bf844.*"` returned empty — either retention dropped, label mismatch, or log scraping wasn't covering the pod

**Hypothesis:** The ~15-min restart cadence on the old pod was caused by the pre-cutover MinIO config combined with something transient in the S3 dependency chain (MinIO or the secret drift during cutover). The rollout that created the new pod cleared whatever state was causing probe failures. The current pod has been stable for ~15 min at plan time, and its image is identical (`5d0414d5`) — so nothing in the app changed.

- [ ] **Step 4.1: Attempt to recover historical logs from Loki**

Try broader queries — the label `pod` might not be indexed as a matcher, or the old pod's logs may only be present under `service_name`:

```bash
kubectl -n default delete pod loki-probe --ignore-not-found --wait=true
kubectl -n default run loki-probe --image=curlimages/curl --restart=Never --command -- sleep 300
kubectl -n default wait --for=condition=Ready pod/loki-probe --timeout=30s

# Try 1: by app label
kubectl -n default exec loki-probe -- sh -c '
START=$(( $(date +%s) - 172800 ))000000000
END=$(date +%s)000000000
curl -sG --data-urlencode "query={namespace=\"default\",service_name=~\"athenaeum.*\"}" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode "limit=50" \
  "http://loki:3100/loki/api/v1/query_range"
' | python3 -m json.tool | head -80

# Try 2: by container name
kubectl -n default exec loki-probe -- sh -c '
START=$(( $(date +%s) - 172800 ))000000000
END=$(date +%s)000000000
curl -sG --data-urlencode "query={namespace=\"default\",container=\"backend\"} |= \"athenaeum\"" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode "limit=50" \
  "http://loki:3100/loki/api/v1/query_range"
' | python3 -m json.tool | head -80

kubectl -n default delete pod loki-probe --wait=false
```

If any query returns results:
- Search for `error`, `OOMKilled`, `readiness`, `liveness`, `panic`, `connect` around the 15-min cadence
- Root cause documented → update memory → end of task

If all queries empty: proceed to Step 4.2 (accept apparent fix).

- [ ] **Step 4.2: Run a stability watch**

```bash
# 30-minute soak test
for i in $(seq 1 6); do
  sleep 300
  kubectl -n default get pod -l app=athenaeum,component=backend \
    -o jsonpath='{range .items[*]}{.metadata.name}{" restarts="}{.status.containerStatuses[*].restartCount}{" phase="}{.status.phase}{"\n"}{end}'
done
```

Expect all 6 snapshots to show `restarts=0 phase=Running` on the same pod. Any restart → capture `kubectl logs --previous` immediately and investigate.

- [ ] **Step 4.3: Document the outcome**

Update `project_phase5_completion_2026_04_08.md` memory:
- Mark item (d) as either "root cause: <X>, fixed by <Y>" or "unreproducible after 2026-04-08 rollout; no historical logs available; monitoring for recurrence"
- If no root cause found: add a follow-up note to review again if another restart cycle begins

**No commit** unless a code/config change is made.

---

## Self-Review

**Spec coverage:**
- Task 1 (mas config): Steps 1.1–1.10 cover secret backup, key extraction, patching, template ConfigMap, init container, deployment swap, PVC removal, apply, verify, commit. ✓
- Task 2 (plex-backup): decision captured in migration doc. ✓
- Task 3 (S3 identities): mapping verification, creds generation, identity creation, per-service rotation, admin audit, runbook. ✓
- Task 4 (athenaeum): historical log recovery attempt, soak test, memory update. ✓

**Placeholder scan:** None. Every step has concrete commands and the ConfigMap is fully inlined.

**Type consistency:** The secret key names used in Task 1 init container env vars (`mas_db_password`, `mas_admin_token`, `mas_smtp_password`, `mas_encryption_secret`, `mas_client_secret`, `mas_keycloak_client_secret`, `mas_key_rsa/ec_p256/ec_p384/ec_k256`) match the keys patched in Step 1.3 and documented in Step 1.7.

**Open risks:**
- Task 1 Step 1.6: `terraform state rm` without a subsequent `terraform import` elsewhere — the PVC stays in the cluster but TF forgets it. If someone later runs `terraform apply` with `-refresh-only` behaviours that reconcile removed resources, they won't touch it. Safe for rollback.
- Task 3 ordering: doing all 6 services in one session risks cascading failures. Plan says "one at a time" — stick to it.
- Task 4 may conclude without a root cause. That's an acceptable outcome per the plan, but flag it clearly in the memory.
