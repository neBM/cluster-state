# Native GitLab Runner metrics

The two architecture acquisition managers use the existing pinned GitLab Runner
19.5.2 listener. There is no exporter, sidecar, custom endpoint or CI instrumentation.

## Collection and access

- `runner-base/fragments/10-global.toml` sets top-level
  `listen_address = ":9252"`, before any TOML tables. Each manager's production
  config generator reads this global fragment from its architecture-specific
  `any` template. Enabling the listener requires a manager restart.
- The common `45-feature-flags.toml` fragment sets
  `[runners.feature_flags] FF_EXPORT_HIGH_CARDINALITY_METRICS = true`. Every
  rendered registration inherits it, including both architecture-specific `any`
  variants; the registration configuration prevents CI-variable overrides.
  The listener alone does not enable phase histograms (the flag defaults false).
- The single `default/gitlab-runner-metrics` ClusterIP Service selects
  `app: gitlab-runner`: both manager Pods, not ephemeral CI job Pods (which use
  `ci.brmartin.co.uk/job`). Its real TCP port is 9252, targeting the manager's
  named `metrics` port. Only the Service has `prometheus.io/*` scrape annotations.
- The existing VictoriaMetrics service-endpoints job discovers each manager
  endpoint at `/metrics` every 15 seconds. No collector configuration changes or
  duplicate annotated Pod targets are needed. The actual Service port avoids
  reliance on the unrelated existing annotation port-rewrite regex.
- The matching CiliumNetworkPolicy enables default-deny ingress and permits only
  TCP 9252 from Pods in `default` with both
  `app.kubernetes.io/name: victoriametrics` and
  `app.kubernetes.io/instance: victoriametrics`. Explicit deny entities are
  `world`, `host`, and `remote-node`, following the existing private-listener
  convention. No egress rules or egress default-deny are added: acquisition,
  Kubernetes API, DNS and cache traffic retain their existing behavior.
- There is no Ingress, NodePort, hostPort, host networking or new credential.
  The native socket also exposes debug/pprof, so it must remain internal. Node
  administrators remain trusted; Cilium documents a local-host exemption unless
  `allow-localhost=policy` is configured. Do not claim live node-origin isolation
  from source rendering alone; verify effective enforcement during rollout.

## Native histogram semantics and budget

| Histogram family | Additional labels beyond `runner`, `runner_name`, `system_id` |
|---|---|
| `gitlab_runner_job_duration_seconds` | `mode` |
| `gitlab_runner_job_queue_duration_seconds` | `project_jobs_running` |
| `gitlab_runner_job_stage_duration_seconds` | `stage` |

Use the `_bucket`, `_sum` and `_count` samples, not the unsuffixed family name as
if it were a scalar. Phase labels are Runner execution phases such as
`prepare_executor`, `prepare_script`, `get_sources`, `restore_cache`,
`download_artifacts`, `step_script`, `after_script`, cache archive, artifact
upload and cleanup. They are not `.gitlab-ci.yml` pipeline stage names, individual
commands or test durations. No project, pipeline or job identity labels are
added to these histograms. The native `runner` label is Runner's shortened token
identifier, not the authentication token; treat internal metrics accordingly.

Each histogram has ten finite bucket boundaries plus `+Inf`, `_sum` and `_count`:
13 time series per observed label combination. Four registrations across two
stable manager system IDs create five registration/system-ID pairs because
`any` is served by both managers. Budget at most **975 phase series** for the
14 predefined phase names plus ordinary `step_script` (5 × 15 × 13). Including
native `step_run` and `concrete` paths gives a conservative **1,105 phase-series
budget** (5 × 17 × 13). This is an estimate for the current native phase/step
vocabulary, not a hard runtime cap: new server-supplied step names, Runner
upgrades, identity rotations or scrape target churn require reassessment.
The listener also exports other native Runner/Go/process metrics; the phase
budget is not an upper bound for the whole endpoint. In particular, the
server-supplied `project_jobs_running` queue label is a count, not project
identity, but is not globally bounded by a manager's concurrency setting.

Histograms aggregate observations across jobs, without historical backfill.
Skipped phases may contribute very short observations and retries may contribute
multiple observations. Metrics are in memory, reset on manager restart and
appear as corresponding jobs/phases are observed. Scrapes and phase callbacks
add bounded work for the current registration/phase vocabulary, but no measured
CPU/memory overhead claim is made before rollout.

## Verification and rollout boundary

Focused source checks:

```sh
uv run --offline --script scripts/test_gitlab_runner_config.py
python3 scripts/validate_gitlab_runner_templates.py
kubectl kustomize infrastructure/shared-services/gitlab-runner > /dev/null
```

The existing generator test exercises both complete effective manager configs,
all five mounted registration variants, credential escaping and file modes.
It also checks the listener, phase flag, manager-only Service and ingress fence.
Use `RUNNER_CONFIG_CONTAINER=1` with the existing pinned BusyBox image for the
native generator path. Full canonical repository CI remains a separate gate.

Rollout is not performed by these checks. The rollout owner must preserve the
existing paused states of registrations 2, 3, 4 and 5, admit zero active CI before
recreating managers, and restore those exact paused states afterward. Keep both
manager concurrency values at 1 and every registration limit at 1; preserve
request concurrency, native helper selection, immutable image pins, requests,
QoS behavior, architecture admission, mount and job-pod isolation contracts.
After reconciliation, verify both unique endpoint targets are up, effective
policy allows the collector and denies unauthorized sources, and native
histogram samples appear after naturally occurring jobs. Do not retry or
manufacture jobs to populate telemetry.

## Supported release references

- [Runner 19.5.2 monitoring](https://gitlab.com/gitlab-org/gitlab-runner/-/blob/v19.5.2/docs/monitoring/_index.md)
- [Native histogram definitions and phase callbacks](https://gitlab.com/gitlab-org/gitlab-runner/-/blob/v19.5.2/commands/builds_helper.go)
- [Feature flag configuration](https://gitlab.com/gitlab-org/gitlab-runner/-/blob/v19.5.2/docs/configuration/feature-flags.md)
- [Phase names and execution paths](https://gitlab.com/gitlab-org/gitlab-runner/-/blob/v19.5.2/common/build.go)
- [Cilium per-direction policy enforcement](https://docs.cilium.io/en/stable/security/policy/intro/)
- [Cilium entities and host policy boundary](https://docs.cilium.io/en/stable/security/policy/language/)
