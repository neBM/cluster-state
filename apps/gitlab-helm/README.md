# Inactive GitLab native-chart candidate

**Preparation only. Not a complete production deployment or an activation approval.**
The `apps` aggregate does not reference this directory. The dedicated Flux leaf
`clusters/k3s-homelab/flux-system/kustomization-gitlab-helm.yaml` is also outside
the Flux root resource list and suspended; the HelmRelease itself is suspended.
Thus broad `apps` readiness does not wait on this release. Do not attach these
routes alongside the legacy routes or resume either fence during preparation.
Legacy GitLab, its image promotion/Renovate ownership, Redis and registry alias
are unchanged. Task1 introduces only controller source, not a live controller install.

## Native lifecycle and identity

- Official `gitlab` chart **10.5.0**, CE **19.5.0**, release `gitlab-helm`, namespace
  `default`. The HelmRelease chart version is the software input; there is no
  independent `global.gitlabVersion` or component image tag override. The adjacent
  chart lock is reviewed archive metadata, not an image promotion mechanism.
- Flux **v2.9.6** official export now includes helm-controller **v1.6.5**. Generate
  with `flux install --export --version=v2.9.6
  --components=source-controller,kustomize-controller,helm-controller,notification-controller`.
  Its upstream `go.mod` uses Helm SDK **v4.2.4**. Other exported objects and existing
  controller overrides are preserved; helm-controller requests **100m / 64Mi**.
- Native migration Job, pre-upgrade hook, dependency init containers, normal
  release readiness and Job waits remain enabled. Both install and upgrade have
  `retries: 0` and `remediateLastFailure: false`: **no automatic uninstall or
  rollback remediation**, including after schema mutation. The chart is not forked.
- Gateway API/Envoy, ingress/certificate controllers, Runner, GitLab Shell and
  GitLab exporter are disabled. No new SSH capability is asserted.

## Preserved tuning / separate overhead

All values below are requests and a memory ceiling; there are no new CPU limits.

| Container | CPU | Memory | Memory limit |
|---|---:|---:|---:|
| Gitaly | 50m | 300Mi | 512Mi |
| KAS | 50m | 128Mi | 512Mi |
| Registry | 100m | 64Mi | 256Mi |
| Sidekiq | 150m | 1600Mi | 2Gi |
| Webservice | 75m | 2100Mi | 3Gi |
| Workhorse | 100m | 32Mi | 256Mi |
| Retained external Redis (not chart-owned) | 50m | 32Mi | 256Mi |
| New Toolbox (vendor request) | 50m | 350M | — |
| Transient native migrations (separate budget) | 75m | 2100Mi | 3Gi |

Singleton replicas/HPA bounds, Sidekiq concurrency 5 and one Puma worker with
threads 1–4 are explicit. Application plus Toolbox and retained Redis requests
625m / approximately 4589.79Mi, excluding init/Job peaks. Controller adds 100m /
64Mi. These are planning requests, not proof of scheduler fit or runtime capacity.

External PostgreSQL keeps the existing `main`/`ci` database arrangement, including
`database_tasks: false` for CI and no prepared statements. Redis is not replaced
or restarted: resque/ActionCable remain DB0; cache1, queues2, shared_state3,
trace_chunks4, rate_limiting5 and sessions6 are carried by the supported native
`global.redis.redisYmlOverride`. Chart10.5's generated fragments apply the global
DB; the override avoids silently moving queued work. KAS uses supported
`customConfig` for DB3. Render checks inspect those effective fragments.

Traefik routes retain GitLab/registry hostnames, wildcard TLS, KAS WebSocket and
Kubernetes-proxy paths. The existing `gitlab-registry-internal` service remains
plain HTTP **443 → 5000**, with its production selector untouched. CoreDNS and CI
still depend on it. Its eventual selector handover must be atomic with cutover;
Task1 deliberately does not claim the alias already targets the new release.

## Required interfaces before activation (not provisioned here)

Existing byte-preserving references: `gitlab-rails-secret/secrets.yml`,
`gitlab-gitaly/token`, `gitlab-shell/.gitlab_shell_secret`,
`gitlab-workhorse/secret`, `gitlab-kas-secret/kas_shared_secret`,
`gitlab-secrets/db_password`, `gitlab-smtp-secret/SMTP_USERNAME` and
`SMTP_PASSWORD`; retain `wildcard-brmartin-tls`. Names/keys are metadata only;
this preparation does not establish existence, content or schema validity.

Future native object-storage interfaces are `gitlab-helm-objectstore/connection`,
`gitlab-helm-registry-storage/config` and `gitlab-helm-backup-config/config`.
Buckets, access, policies, contents, migration, backup/restore and recovery are
not provisioned or qualified by this task. Gitaly requests a retained, scheduler-
selected local RWO volume; its binding and data transfer remain future work,
and node/disk failure requires recovery, not automatic shared-volume failover.

Normalize these remaining native interfaces outside Git before activation:

- `gitlab-helm-registry-auth`: keys `registry-auth.key` / `registry-auth.crt`
  copied from the existing signing bytes/certificate, **not regenerated**;
  preserve issuer `gitlab-issuer`. Signing-key normalization is a separate task.
- `gitlab-helm-kas-private-api/kas_private_api_secret` and
  `gitlab-helm-kas-websocket-token/kas_websocket_token_secret`: map the existing
  identities after private key-format inventory. Do not replace working bytes
  just to satisfy a new Secret name.
- `gitlab-helm-registry-httpsecret/secret` and
  `gitlab-helm-registry-notification/secret` need explicit ownership/provisioning.
- `gitlab-helm-initial-root-password/password` is a chart migration reference,
  **not** proof that existing root credentials/login are preserved. Optional Helm
  test templates also reference `gitlab-helm-gitlab-runner-secret`; do not mistake
  this for enabling a Runner installation or a required integration oracle.
- Toolbox includes *optional* registry/OpenBao DB-password projections even with
  both features disabled. Do not provision/enable a registry metadata DB merely
  to satisfy these optional references.

Shared-secret generation is disabled to avoid generating replacement identities.
KAS backend ports and external path are rendered, but chart10.5 does not emit the
legacy Rails `external_k8s_proxy_url` field from an `externalK8sProxyUrl` value.
Do not add an unused value and call it qualification: verify the native GitLab19.5
proxy-URL behavior and routed KAS/Runner operation before activation. SMTP uses
the existing STARTTLS/login host, port, domain and Secret keys; real delivery is
also an activation gate. Full existing-user Git/registry/Runner/KAS, data,
metrics and restore acceptance remains outstanding and parent-owned.

## Local / CI validation

Run `./scripts/validate_gitlab_helm.sh` with standalone `kustomize`, `uv` and Helm
**v4.2.4** on PATH (or set `HELM` to that executable). It fetches the official index,
pulls the exact chart via native Helm, checks archive digest against the official
index and reviewed lock, lints/renders, and runs focused source/render mutations.
An optional `GITLAB_HELM_CHART_ARCHIVE` accelerates local archive access only;
the index and digest checks still run. No Helm install/upgrade or API access occurs.
`./scripts/validate_kustomize.sh` invokes it, including in the existing required
manifest CI job for relevant MR and main changes. That job downloads and verifies
the official Helm4 binary instead of using an ambient Helm3.

These checks enforce the inactive preparation contract. Later approved activation
must deliberately update that contract; bypassing or permanently suppressing it
is not the update lane. Native CI execution, independent review, source/image
qualification and all live/recovery gates remain required before delivery.

## Inactive upgrade admission / independent recovery foundation (Task2a)

The isolated candidate now also declares **`gitlab-helm-recovery-windsor`**:
`windsor-nfs-rwx`, RWX, **100Gi request**, Flux prune disabled and retain intent.
This is independent NAS recovery storage, **not a directory in a Restic repository**.
It is not reachable from either active root. No claim, export or backup is claimed
provisioned by a source render. NFS requests are **not quotas**: before use the
operator must inventory the retained export and verify real free space, expected
ownership, NAS ACL/squash behavior and capacity for the required retention.

The HelmRelease uses native **`postRenderStrategy: combined`** and exactly one
JSON6902 patch targeting `Job/default/gitlab-helm-gitlab-upgrade-check`. It adds
`site-upgrade-admission` before the unchanged upstream `run-check`. The upstream
hook weights (-11 ConfigMap / -10 Job), scripts, previous chart-info, native
migration jobs, dependency checks, release waits and no-remediation policy remain.
Target `GITLAB_VERSION` and `CHART_VERSION` are **copied from upstream run-check
with JSON6902 `copy`**, never separately pinned in the init container. The ordinary
candidate-generated `gitlab-helm-upgrade-admission` ConfigMap must be present before
an upgrade; it is not a second Helm hook or a sequencing controller.

Admission uses the parent-verified PostgreSQL **17.10-bookworm** client image:
`docker.io/library/postgres@sha256:9b18b78397054fce88a9552e9d5a3ad5bb7fd258c5b3cc1c5028e46373d6ea8f`.
It mounts only previous chart-info, the admission script, the existing
`gitlab-secrets/db_password` projection, dedicated in-memory private workspace and
recovery claim. No API token or new RBAC is needed. The init runs **1000:1000**,
non-root, without privilege escalation/capabilities and with a read-only root FS;
its transient request is 50m / 128Mi with a 512Mi memory ceiling, separate from
application tuning. Native run-check remains UID65534. Pod `fsGroup` is explicitly
removed through supported chart values so Kubernetes does **not** recursively
chown/chmod the retained NAS share. Secret/script projections are read-only0444
and are not mounted into other containers; the temporary libpq password file is
private0600, removed on exit, and the password is never passed in argv/logs/env.

### Fail-closed policy and archive contract

- Previous versions come from the **previous deployed** chart-info files. Stable
  numeric versions (optional single `v` prefix) are required on both sides;
  malformed, prerelease, unknown and downgrade inputs fail closed.
- The reviewed initial envelope is previous/target **CE19.5.x / chart10.5.x**:
  same-version chart maintenance and forward patches are allowed. Parent migration
  statuses **3=finished / 6=finalized** are supported by the exact GitLab v19.5.0
  `batched_migration.rb` model. All other/NULL parent statuses deny admission;
  historical child-job status numbers are not substituted for parent semantics.
  **No cross-minor or major progression is admitted yet**, including nominal
  required-stop targets. A future transition needs authoritative previous-model,
  applicable x.2/x.5/x.8/x.11 stop and latest-patch policy review, not a permissive
  numeric comparison or another target pin. Native upstream checks still run.
- Main and CI connection settings must remain the same DB with CI
  `database_tasks: false`; split topology is denied, not silently partially dumped.
  Both logical connections are observed and their actual server/DB identities
  compared. Native public tables and a nonempty, valid `schema_migrations`
  fingerprint guard against a missing/unrecognized schema. Chart-info is the
  previous-release authority; the DB fingerprint is **not a version attestation**.
- PostgreSQL clients and server must be major17. Connections use `psql -X`,
  `ON_ERROR_STOP`, no password prompting and explicit read-only transaction
  defaults. The query verifies read-only is on. Connection timeout is10s,
  statement/idle timeout30s and lock timeout5s; query/list processes are bounded
  to60s and the fresh dump to600s (with bounded termination grace). Query failure,
  missing tables/columns, malformed results or nonterminal/unknown state deny.
  No migrations are executed or finalized by this script.
- Under `umask077`, the script creates **only its own** `db-archives/` namespace
  (0700, UID/GID1000). An existing namespace with different ownership/modes or a
  symlink is rejected **without chmod/chown repair**. Each attempt creates a unique
  private staging directory and custom-format `database.dump.partial`; empty or
  failed dumps deny. It computes a checksum, lists with `pg_restore --list`, checks
  readback, writes private metadata/list/checksum files (0600), syncs files,
  rechecks both DB identities/schema/status observations, and atomically publishes
  the directory without replacing another archive. A final checksum readback is
  required. Errors block the hook; private unpublished staging is cleaned up.
  Successful archives are retained; this tranche deliberately does not prune them.

**`pg_restore --list` and checksum readback prove archive readability/integrity,
not a successful database restore.** An online DB-only archive does not include
repositories, object blobs, Redis state or the private secrets needed to decrypt
and restore GitLab, and is not a cross-component point-in-time recovery set while
writers remain active. Final cutover needs its separate write fence, native full
backup/export, independently retained secret custody and qualified restore.

### Required later gates; not Task2 completion

**Initial install/adoption does not run a pre-upgrade hook.** Before first cutover
the parent/operator must explicitly perform equivalent version/model, read-only
DB/main-CI identity/status, client, NAS/private-archive and actual restore checks
against the observed legacy installation. Do not fabricate previous chart-info to
pretend a legacy installation already had this Helm release.

This tranche has no recurring export/retention implementation, S3 provisioning or
client qualification. Before activation, parent-owned remaining gates include:

1. Independent exact-source review and canonical CI; installed controller/CRD
   support for combined rendering and an **isolated native Helm4/controller
   hook-ordering exercise** proving a denied init prevents ordinary app/migration
   changes. Helm release/hook records may still change on denial.
2. Actual non-root NAS write/readback/capacity/export-inventory qualification;
   real disposable PostgreSQL17 dump **and restore**, including this native schema
   query and timeouts. Fixture clients are not that evidence.
3. Qualified native Rails/registry/Toolbox S3 clients, scoped credentials, full
   backup/restore, recurring native backup plus independent NAS export,
   explicit archive/export retention and freshness/failure monitoring. Without
   those later policies this foundation is not production recovery.

The focused validator renders the locked official chart with Helm4 in upgrade
mode, applies the exact release patch with real Kustomize, counts exactly one hook
before/after, verifies copied env and unchanged upstream resources/check content
(apart from native omission of null metadata annotations). It rejects unmatched,
duplicate and reshaped targets. `scripts/test_gitlab_upgrade_admission.py` exercises
the actual shell script with bounded **command-double fixtures** and real local
permissions/hash/publication operations. Neither test path accesses a cluster,
uses live credentials, proves hook ordering or proves a real backup/restore.
