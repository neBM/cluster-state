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

Native object-storage interfaces are `gitlab-helm-objectstore/connection`,
`gitlab-helm-registry-storage/config` and `gitlab-helm-backup-config/config`.
The parent reports private native Secret/bucket provisioning and disposable native
client checks; source renders do not prove their content, production migration or
full backup/restore. Gitaly requests a retained, scheduler-
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
  Admission itself never prunes; the independent exporter below retains fourteen
  validated completed DB archives only after a new qualified NAS publication.

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

Task2a alone provided no recurring export/retention. Task2b source below adds an
inactive, conservative export checkpoint, not a fully qualified recovery endpoint.
Before activation, parent-owned remaining gates include:

1. Independent exact-source review and canonical CI; installed controller/CRD
   support for combined rendering and an **isolated native Helm4/controller
   hook-ordering exercise** proving a denied init prevents ordinary app/migration
   changes. Helm release/hook records may still change on denial.
2. Actual non-root NAS write/readback/capacity/export-inventory qualification;
   real disposable PostgreSQL17 dump **and restore**, including this native schema
   query and timeouts. Fixture clients are not that evidence.
3. Parent reports native Rails/registry/Toolbox disposable S3 client checks passed;
   full native backup/restore, empty-bucket policy, actual recurring NAS export,
   retention/capacity and freshness/failure monitoring remain qualification gates.
   Without those gates this foundation is not production recovery.

The focused validator renders the locked official chart with Helm4 in upgrade
mode, applies the exact release patch with real Kustomize, counts exactly one hook
before/after, verifies copied env and unchanged upstream resources/check content
(apart from native omission of null metadata annotations). It rejects unmatched,
duplicate and reshaped targets. `scripts/test_gitlab_upgrade_admission.py` exercises
the actual shell script with bounded **command-double fixtures** and real local
permissions/hash/publication operations. Neither test path accesses a cluster,
uses live credentials, proves hook ordering or proves a real backup/restore.

## Inactive native backup and independent NAS ownership (Task2b checkpoint)

### Native storage and credentials

Artifacts, LFS, uploads and packages are explicitly enabled in their own
`gitlab-artifacts`, `gitlab-lfs`, `gitlab-uploads`, `gitlab-packages` buckets;
registry uses `gitlab-registry`. Native backup tars use `gitlab-backups`, restore
safety/scratch uses `gitlab-restore-scratch`. External diffs, Terraform state,
dependency proxy, CI secure files, agent plan content, CI catalog bundles and
Pages are explicitly disabled through chart-supported values. Parent must inventory
any populated legacy type before retirement: disabling a type does not migrate it.

Rails uses consolidated native Fog connection YAML and `proxy_download: true` for
the internal S3 endpoint. Registry uses a **block YAML storage fragment**, not a
document wrapped in `storage:` or JSON: the native init script inserts it textually.
Parent's actual registry qualification required **integer `s3_v2.chunksize: 5242880`**
and explicit boolean `delete.enabled: true`; the earlier discovery's string `5M`
example is superseded. `registry.storage.redirect.disable: true` is supported
native values, and registry metadata DB stays disabled. Toolbox uses native
**s3cmd INI**, not Rails YAML/COSI BucketInfo.

The operator owns SeaweedFS's native **GitLab-only multi-bucket identity** and
the three native Secrets outside Git. Unmodified Toolbox needs access to **all
GitLab data buckets**, backup tar bucket and restore scratch: the backup utility's
`--s3config` does not reconfigure the object-storage library's default s3cmd.
No administrator/shared unrelated-bucket key, COSI-only multi-bucket fiction or
formatter controller is introduced. Rotate privately as a synchronized identity +
three-native-Secret change, transition/reload actual consumers, requalify allowed
operations/multipart and unrelated-bucket denial, then verify old-key rejection.
Do not assume zero-downtime dual-key support. The export mounts this existing backup
Secret only; although its **code** only lists/gets `gitlab-backups`, the shared native
Toolbox credential is broader than read-only. No DB/Redis/signing/API token is mounted.

### Schedules, transient resources and publication

- The chart's **native** Toolbox backup CronJob is configured for **01:00
  Europe/London**, Forbid, **suspended**, start deadline1800s, active deadline10800s,
  backoff0, restartNever, two successful/two failed Job histories and native
  `--maximum-backups 7`. Its native image derivation, command/config/init/mounts
  are unchanged. A retained local RWO **100Gi** backup staging claim and transient
  request100m/512Mi, memory ceiling2Gi are separate from steady application sizing.
  Staging must hold native unpacked data plus tar/compression workspace;100Gi is a
  preparation request, **not observed capacity acceptance**, especially for registry.
- The independent ordinary NAS export CronJob is **02:00 Europe/London**, Forbid,
  **suspended**, start deadline1800s, active deadline7200s, backoff0/restartNever,
  histories2/2 and transient request50m/128Mi, memory ceiling512Mi. Schedule ordering
  is not a dependency: backup filename and native metadata must independently be
  no older than **26h** (at most5min clock skew into the future).
- The exact parent-qualified Toolbox digest
  `registry.gitlab.com/gitlab-org/build/cng/gitlab-toolbox-ce@sha256:6038bfd42aa8bae1f63c25eb366c0d5bf79395db348ded1f43bf76ca1323bf35`
  is a **file-transfer-only utility dependency**. It does not run Rails/backup creation,
  change any application image or become a second desired GitLab version input.
  The parser supports the CNG19.5 metadata model and requires the backup version to
  match the utility's own `/srv/gitlab/VERSION`; future release changes need explicit
  compatible transfer/parser qualification rather than silently accepting a new format.
- The Python standard-library script invokes native s3cmd with the existing INI,
  selects the newest completed native filename, reads the tar without filesystem
  extraction, checks header/payload readability, gzip CRCs, native scalar metadata,
  version, creation time, main DB presence and the required component/skipped contract.
  It rejects unsafe/duplicate members, links, malformed metadata, missing/partial/
  stale inputs, server-side repository backups, required skips and unsafe destinations.
  No repository bundle count is invented: metadata must not skip repositories,
  but a legitimately empty repository population need not have a bundle per project.
- UID/GID1000, umask077, owned dirs0700/files0600; no fsGroup or chmod/chown repair
  over unrelated NAS paths. Only `gitlab-helm-recovery-windsor`, read-only native
  backup config and script are mounted. There is no service-account token/RBAC.
  Under an owned-directory lock, download goes to a unique private `.partial`
  directory, then checksum/private readback/fsync, atomic directory rename and final
  checksum readback. Failure preserves prior completed points; only this invocation's
  unpublished temporary directory is cleaned. NFS rename/fsync/locking/ACL/squash,
  disk-full and process-interruption behavior still require actual NAS qualification.
- After a new qualified publication, retain **seven NAS completed exports** and
  **fourteen completed admission DB archives**, ordered by native backup epoch and
  admission `observed_at`, respectively. Validate exact owned completed file sets,
  permissions and checksum readback before pruning. Unknown names and others'
  `.partial`/`.admission` staging are never pruned; the only good point is not removed.
  S3's native `--maximum-backups 7` is **separate** and counts native tars, not
  exporter-qualified restore sets. Failed/ambiguous exports do not trigger NAS/DB
  pruning: alert and budget space rather than deleting recovery history to hide failure.

### Explicit source residual and live qualification gates

**This checkpoint cannot yet accept every legitimate empty enabled bucket.** Exact
[CNG19.5 object-storage source](https://gitlab.com/gitlab-org/build/CNG/-/blob/v19.5.0/gitlab-toolbox/scripts/lib/object_storage_backup.rb)
returns without an archive both on bucket-existence failure (including AccessDenied)
and on an empty synchronized directory. Native
[`get_skipped`](https://gitlab.com/gitlab-org/build/CNG/-/blob/v19.5.0/gitlab-toolbox/scripts/bin/backup-utility)
labels **both** as skipped. The tar alone contains no authoritative distinction.
The exporter therefore denies either case for enabled components; it does **not**
infer successful empty backup from current bucket contents or invent an archive
member/manifest to claim that gap solved. This intentionally narrower fail-closed
checkpoint is **not full Task2b acceptance or an activation approval**. Parent must
resolve a source-backed backup-time empty-versus-failure witness/policy before the
endpoint can support ordinary empty data; seeded qualification alone is not that fix.

Monitoring is also an explicit coherent follow-up: extend the established Grafana
provisioned alert rules at
`infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml`, following its
Restic failure/last-success conventions. Before unsuspension, alert on native backup
and independent export failures and >26h stale/missing successful publication,
including no first success, gated against intentionally suspended preparation.
No new monitoring service is needed; a successful native Job alone is not full-data
backup proof. Neither schedule is automatically activated by the other.

Parent owns exact-source review/canonical CI, actual image/script execution,
NAS retained-export inventory/free space/private custody, seeded **all enabled
types** in real full backup and native restore, client regressions, final write fence
and activation/unsuspension. Restore from a **NAS-resident** tar with matching CE
version using native `backup-utility --restore -f file:///...` in an isolated
DB/Gitaly/object-storage target; native restore can delete/replace bucket contents.
Retain Rails encryption/signing/KAS and other restore secrets separately and privately:
they are not supplied by this tar. Tar/CRC/hash/listing checks are integrity/readability,
**not restore proof or an online cross-component point-in-time guarantee**.

`scripts/test_gitlab_nas_export.py` runs the real script with **fixture s3cmd** and
real local tar/gzip/permissions/hash/fsync/publication/retention. It is not S3, NAS,
actual native backup or restore evidence; the existing locked Helm4 real-render tests
check the native backup and independent exporter resources and inactive fences.
