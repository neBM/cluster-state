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

The HelmRelease uses native **`postRenderStrategy: combined`** with one admission
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
  Admission itself never prunes; the native producer publication below retains fourteen
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
   full native backup/restore, actual recurring producer-owned NAS publication,
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
Do not assume zero-downtime dual-key support. The producer uses the chart's existing
native Toolbox configuration/Secret mounts, including DB/repository access; no
second credential identity, signing-key copy, sidecar or API/RBAC access is added.

### One native producer invocation and publication

- The chart's native Toolbox backup CronJob alone runs at **01:00 Europe/London**,
  Forbid, **suspended**, start deadline1800s, active deadline10800s, backoff0,
  restartNever and histories2/2. There is **no separate export CronJob**, independently
  pinned transfer image, remote archive selection or receipt/attestation protocol.
  Independence means that the recovery **copy is off the S3 backend**, on the NAS.
- The existing combined postrenderer has a second, exact-name JSON6902 target for
  `CronJob/default/gitlab-helm-toolbox-backup`. It tests the native container/args,
  retains the native S3 config copy and CNG entrypoint, then invokes the helper in
  the **chart-selected native Toolbox image**. Config init/env/native Secrets,
  resources and local staging remain native. Only this backup pod gains the script
  and NAS mounts, loses API-token automount and `fsGroup` (no recursive NAS ownership
  repair). The Toolbox Deployment and upgrade hook patch are not repurposed.
- The helper invokes actual `backup-utility --skip
  external_diffs,terraform_state,pages,ci_secure_files,agent_plan_content,ci_catalog_bundles
  --skip-cleanup`. The single comma-list skips only disabled native optional types;
  DB, repositories and all five enabled object-storage types remain unskipped.
  It captures complete combined producer output/status in a local private0600
  `/srv/gitlab/tmp/.native-backup.*.log`, never echoed to Job logs. These diagnostics
  survive failure/cleanup; budget and manage their private custody on the local volume.
- **Exact native-output dependency, checked against CNG19.5.0 source:**
  [object_storage_backup.rb](https://gitlab.com/gitlab-org/build/CNG/-/blob/v19.5.0/gitlab-toolbox/scripts/lib/object_storage_backup.rb)
  prints `Unable to check existence of bucket ...` but returns success on failed
  bucket checks. The helper rejects that output even on process exit0. For every
  enabled type it requires the native adjacent `Dumping <type> ...` / `empty` or
  `done` lines (ANSI colors removed); native sync/archive errors already exit nonzero.
  This is evidence from the **same producer invocation**, never a later bucket check.
  Requalify these source/output semantics on **every native application update**;
  the 19.5.0 contract and command-double fixtures do not qualify future releases.
  The chart remains the sole release input: the helper reads the chart-selected
  native image's `/srv/gitlab/VERSION`, requires stable numeric `major.minor.patch`
  (no prefix, leading zeros, prerelease or build metadata), and binds the reported
  archive version to that runtime value, with no separately edited application pin.
  Invalid/mismatched versions and changed/incomplete producer output fail closed.
- Select only the local archive named in that invocation's native S3-success line,
  with its version/epoch inside the invocation and a fresh regular local file.
  Read the native tar without extraction, validate headers/end blocks, consume all
  payloads, validate present blob tar/gzip payloads and SQL gzip CRCs, and require
  a nonempty regular main DB payload. Every nonempty enabled blob requires its
  actual regular payload; names supplied as directories are rejected. Legitimate
  empty enabled types may have no payload. Native `backup_information.yml` remains
  **opaque, byte-preserved**, including the actual duplicate `pages` skipped value.
  It is not a second completeness authority. Trusted fixed producer flags preserve
  DB/repository backup; no per-project repository bundle count is invented.
- UID/GID1000, umask077, owned dirs0700/files0600, no chmod/chown repair. Under the
  owned NAS directory lock, copy **that exact local archive** to unique private
  `.partial` staging, write checksum and unchanged native metadata, verify copy hash,
  file/directory fsync, atomically rename the directory, then verify final readback.
  Preserve prior-good/unknown/others' partial paths on failure; clean only this
  invocation's unpublished NAS stage. NAS absence/failure fails the whole Job.
- Only **after qualified NAS publication**, retain **seven** owned complete exports
  and **fourteen** owned completed admission DB archives (native epoch/admission
  `observed_at` order). Validate owned file sets/privacy/checksums before pruning;
  unknown paths/partial staging are untouched. Then run native
  `backup-utility --cleanup --maximum-backups 7` for supported local/S3 cleanup.
  No custom S3 delete/list retention implementation exists. Native producer or NAS
  failure never invokes cleanup/pruning; cleanup failure fails the Job but keeps
  the newly published NAS recovery point. A later native run clears its own native
  working directories as upstream does, not independent NAS history.
- Retained local RWO staging is **100Gi**, transient request100m/512Mi, memory
  ceiling2Gi, separate from steady application sizing. It must hold native unpacked
  data plus tar/compression workspace and retained diagnostics. These requests are
  **not observed capacity acceptance**, especially for registry or an unbounded NFS
  export; inventory and verify capacity rather than deleting history to hide failure.

### Remaining activation and live qualification gates

Monitoring is a separate bounded follow-up and an **activation blocker**. Extend
`infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml` using established
failure/last-success conventions: combined native-backup/NAS-publication Job failure
and >26h stale/missing successful publication, including no first success, gated
against intentionally suspended preparation. A native S3 upload alone is not success
of the combined Job or proof of NAS publication. No new monitoring service is needed.

Parent owns exact-source review/canonical CI, actual native image/helper execution,
NAS privacy/free space/retained inventory, NFS rename/fsync/locking/ACL/squash,
disk-full/interruption behavior, real full native backup and restore with **all
enabled types** (including normal empty-data operation), client regressions, final
write fence and activation. Restore from a **NAS-resident** tar with matching CE
version using native `backup-utility --restore -f file:///...` in an isolated
DB/Gitaly/object-storage target; native restore can delete/replace bucket contents.
Retain Rails encryption/signing/KAS and other restore secrets separately and privately:
they are not supplied by this tar. Tar/CRC/hash/listing checks are integrity/readability,
**not restore proof or an online cross-component point-in-time guarantee**.

`scripts/test_gitlab_nas_export.py` executes the real helper with a **fixture
backup-utility**, not real native backup or S3. Local tar/gzip/privacy/hash/fsync/
publication/retention checks and locked Helm4 renders qualify source behavior only.
They do not prove native image execution, NAS durability or successful recovery.
