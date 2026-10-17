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
